import Darwin
import Foundation
import Synchronization
import Testing
@testable import SunshineCore

/// Every suite that spawns processes nests in here, so they run one at a time and the
/// fd-leak count isn't disturbed by another suite's pipes.
@Suite(.serialized) enum ProcessSpawningTests {}

/// Collects callback lines from reader threads.
final class LineBox: Sendable {
    private let storage = Mutex<[String]>([])
    func append(_ s: String) { storage.withLock { $0.append(s) } }
    var lines: [String] { storage.withLock { $0 } }
}

let sh = URL(fileURLWithPath: "/bin/sh")

/// Open pipe fds in this process.
func openPipeCount() -> Int {
    (0..<Int32(getdtablesize())).filter { fd in
        var st = stat()
        return fstat(fd, &st) == 0 && (st.st_mode & S_IFMT) == S_IFIFO
    }.count
}

/// pids in process group `pgid` (via /usr/bin/pgrep, run through ProcessRunner itself).
func processes(inGroup pgid: pid_t) async throws -> [String] {
    let out = LineBox()
    _ = try await ProcessRunner().run(executable: URL(fileURLWithPath: "/usr/bin/pgrep"),
                                      args: ["-g", String(pgid)], onStdoutLine: out.append)
    return out.lines
}

extension ProcessSpawningTests {
    @Suite struct ProcessRunnerTests {
        @Test func oneMegabyteOnEachStreamDoesNotDeadlock() async throws {
            let out = LineBox(), err = LineBox()
            let start = ContinuousClock.now
            // stderr is written first and completely: a runner that read stdout first would deadlock.
            let status = try await ProcessRunner().run(
                executable: sh,
                args: ["-c", "yes 0123456789abcdef | head -c 1048576 >&2; yes 0123456789abcdef | head -c 1048576"],
                onStdoutLine: out.append, onStderrLine: err.append)
            #expect(status == 0)
            #expect(ContinuousClock.now - start < .seconds(5))
            // 1048576 bytes = 61680 lines of 16 chars + newline, then a 16-char partial line.
            for box in [out, err] {
                #expect(box.lines.count == 61681)
                #expect(box.lines.reduce(0) { $0 + $1.utf8.count } == 986_896)
                #expect(box.lines.allSatisfy { $0 == "0123456789abcdef" })
            }
        }

        @Test func cancelKillsGrandchildren() async throws {
            let runner = ProcessRunner()
            let task = Task { try await runner.run(executable: sh, args: ["-c", "sleep 100 & sleep 100"]) }

            var pgid: pid_t?
            for _ in 0..<100 {
                if let pid = runner.processIdentifier, try await processes(inGroup: pid).count >= 3 {
                    pgid = pid
                    break
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            let group = try #require(pgid, "sh and both sleeps never showed up in one process group")

            let cancelled = ContinuousClock.now
            runner.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(ContinuousClock.now - cancelled < .seconds(3))
            #expect(try await processes(inGroup: group).isEmpty)
        }

        @Test func taskCancellationCancelsTheChild() async throws {
            let runner = ProcessRunner()
            let task = Task { try await runner.run(executable: sh, args: ["-c", "sleep 100"]) }
            while runner.processIdentifier == nil { try await Task.sleep(for: .milliseconds(20)) }
            let pid = try #require(runner.processIdentifier)
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(try await processes(inGroup: pid).isEmpty)
        }

        @Test func cancelBeforeRunDoesNotSpawn() async throws {
            let runner = ProcessRunner()
            let marker = FileManager.default.temporaryDirectory.appendingPathComponent("sunshine-\(UUID().uuidString)")
            runner.cancel()
            await #expect(throws: CancellationError.self) {
                try await runner.run(executable: URL(fileURLWithPath: "/usr/bin/touch"), args: [marker.path])
            }
            #expect(!FileManager.default.fileExists(atPath: marker.path))
            // The cancel applies to one run only.
            #expect(try await runner.run(executable: URL(fileURLWithPath: "/usr/bin/true"), args: []) == 0)
        }

        @Test func runInAlreadyCancelledTaskDoesNotLockTheRunner() async throws {
            let runner = ProcessRunner()
            let task = Task { () async throws -> Int32 in
                while !Task.isCancelled { await Task.yield() }
                return try await runner.run(executable: URL(fileURLWithPath: "/usr/bin/true"), args: [])
            }
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(runner.processIdentifier == nil)
            #expect(try await runner.run(executable: URL(fileURLWithPath: "/usr/bin/true"), args: []) == 0)
        }

        @Test func noFileDescriptorLeakOver50Runs() async throws {
            let runner = ProcessRunner()
            _ = try await runner.run(executable: sh, args: ["-c", "echo warmup; echo warmup >&2"])
            let before = openPipeCount()
            for i in 0..<50 {
                let status = try await runner.run(executable: sh, args: ["-c", "echo out \(i); echo err \(i) >&2"])
                #expect(status == 0)
            }
            #expect(openPipeCount() == before)
        }

        @Test func childInheritsOnlyStandardDescriptors() async throws {
            // A descriptor without FD_CLOEXEC that a plain fork/exec would leak into the child.
            let leaked = dup2(open("/dev/null", O_RDONLY), 200)
            #expect(leaked == 200)
            defer { close(leaked) }
            #expect(fcntl(leaked, F_GETFD) & FD_CLOEXEC == 0)

            // Inspect a live child from outside with lsof: its numeric fds must be exactly 0, 1, 2.
            let runner = ProcessRunner()
            let child = Task { try await runner.run(executable: URL(fileURLWithPath: "/bin/sleep"), args: ["30"]) }
            while runner.processIdentifier == nil { try await Task.sleep(for: .milliseconds(20)) }
            let pid = try #require(runner.processIdentifier)
            try await Task.sleep(for: .milliseconds(100))  // let exec finish

            let fields = LineBox()
            _ = try await ProcessRunner().run(executable: URL(fileURLWithPath: "/usr/sbin/lsof"),
                                              args: ["-a", "-p", String(pid), "-F", "f"],
                                              onStdoutLine: fields.append)
            let fds = fields.lines.filter { $0.hasPrefix("f") }.compactMap { Int($0.dropFirst()) }
            runner.cancel()
            await #expect(throws: CancellationError.self) { try await child.value }
            #expect(fds.sorted() == [0, 1, 2])
        }

        @Test func stdinIsDevNull() async throws {
            let out = LineBox()
            let status = try await ProcessRunner().run(executable: sh, args: ["-c", "wc -c; echo done"],
                                                       onStdoutLine: out.append)
            #expect(status == 0)
            #expect(out.lines.map { $0.trimmingCharacters(in: .whitespaces) } == ["0", "done"])
        }

        @Test func childEnvironmentIsMinimal() async throws {
            let out = LineBox()
            _ = try await ProcessRunner().run(executable: URL(fileURLWithPath: "/usr/bin/env"), args: [],
                                              onStdoutLine: out.append)
            let keys = Set(out.lines.compactMap { $0.split(separator: "=", maxSplits: 1).first.map(String.init) })
            #expect(keys == ["PATH", "HOME", "TMPDIR", "LANG"])
            #expect(out.lines.contains("PATH=/usr/bin:/bin"))
        }

        @Test func exitStatusIsReturned() async throws {
            #expect(try await ProcessRunner().run(executable: sh, args: ["-c", "exit 7"]) == 7)
        }

        @Test func signalDeathIsReported() async throws {
            await #expect(throws: ProcessRunnerError.terminatedBySignal(SIGKILL)) {
                try await ProcessRunner().run(executable: sh, args: ["-c", "kill -9 $$"])
            }
        }

        @Test func carriageReturnsSplitLines() async throws {
            let out = LineBox()
            _ = try await ProcessRunner().run(executable: URL(fileURLWithPath: "/usr/bin/printf"),
                                              args: ["a\\rb\\r\\nc\\n\\nd"], onStdoutLine: out.append)
            #expect(out.lines == ["a", "b", "c", "d"])
        }

        @Test func missingExecutableFailsToSpawn() async throws {
            await #expect(throws: ProcessRunnerError.spawnFailed(executable: "/nonexistent/yt-dlp", errno: ENOENT)) {
                try await ProcessRunner().run(executable: URL(fileURLWithPath: "/nonexistent/yt-dlp"), args: [])
            }
        }

        @Test func watchdogFiresOnSilenceBeforeMerger() async throws {
            let runner = ProcessRunner()
            runner.watchdog(inactivity: .milliseconds(500))
            let start = ContinuousClock.now
            await #expect(throws: ProcessRunnerError.watchdogTimeout(inactivity: .milliseconds(500))) {
                try await runner.run(executable: sh, args: ["-c", "echo '[download] Destination: x.mp4'; sleep 30"])
            }
            #expect(ContinuousClock.now - start < .seconds(4))
        }

        @Test func watchdogDoesNotFireWhileSuspended() async throws {
            let runner = ProcessRunner()
            runner.watchdog(inactivity: .milliseconds(300))
            let out = LineBox()
            let status = try await runner.run(
                executable: sh,
                args: ["-c", "echo '[Merger] Merging formats into \"x.mp4\"'; sleep 1.5; echo done"],
                onStdoutLine: { line in
                    if line.hasPrefix("[Merger]") { runner.suspendWatchdog() }
                    out.append(line)
                })
            #expect(status == 0)
            #expect(out.lines.last == "done")
        }

        @Test func watchdogDoesNotFireWhileOutputFlows() async throws {
            let runner = ProcessRunner()
            runner.watchdog(inactivity: .milliseconds(500))
            let status = try await runner.run(executable: sh,
                                              args: ["-c", "for i in 1 2 3 4 5 6; do echo $i; sleep 0.2; done"])
            #expect(status == 0)
        }

        @Test func secondConcurrentRunIsRejected() async throws {
            let runner = ProcessRunner()
            let first = Task { try await runner.run(executable: sh, args: ["-c", "sleep 100"]) }
            while runner.processIdentifier == nil { try await Task.sleep(for: .milliseconds(20)) }
            await #expect(throws: ProcessRunnerError.alreadyRunning) {
                try await runner.run(executable: sh, args: ["-c", "true"])
            }
            runner.cancel()
            await #expect(throws: CancellationError.self) { try await first.value }
        }
    }
}
