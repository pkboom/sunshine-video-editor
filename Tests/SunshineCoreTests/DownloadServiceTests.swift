import Foundation
import Synchronization
import Testing
@testable import SunshineCore

/// Records which helpers were looked up.
final class LocateLog: Sendable {
    private let storage = Mutex<[Helper]>([])
    func append(_ h: Helper) { storage.withLock { $0.append(h) } }
    var helpers: [Helper] { storage.withLock { $0 } }
}

/// A Downloads dir plus a fake `yt-dlp` shell script standing in for the bundled helper.
/// The script records its argv to `argvFile` and its pid to `pidFile`.
struct FakeYTDLP {
    let temp: TempDir
    let downloads: URL
    let script: URL
    let argvFile: URL
    let pidFile: URL
    let log = LocateLog()

    init(body: String) throws {
        temp = try TempDir()
        downloads = try temp.dir("Downloads")
        argvFile = temp.url.appendingPathComponent("argv.txt")
        pidFile = temp.url.appendingPathComponent("pid.txt")
        let prologue = """
        #!/bin/sh
        printf '%s\\n' "$@" > '\(argvFile.path)'
        echo $$ > '\(pidFile.path)'
        for a in "$@"; do case "$a" in temp:*) T="${a#temp:}";; home:*) H="${a#home:}";; esac; done
        [ -d "$T" ] || { echo "ERROR: temp dir $T missing" >&2; exit 3; }

        """
        script = try temp.file("bin/yt-dlp", prologue + body, mode: 0o755)
        try temp.file("bin/ffmpeg", "", mode: 0o755)
        try temp.file("bin/deno", "", mode: 0o755)
    }

    func service(inactivity: Duration = .seconds(60)) -> DownloadService {
        let (bin, log) = (script.deletingLastPathComponent(), log)
        return DownloadService(downloadsDirectory: downloads, inactivityLimit: inactivity) { helper in
            log.append(helper)
            return bin.appendingPathComponent(helper.rawValue)
        }
    }

    var recordedArgv: [String] {
        get throws { try String(contentsOf: argvFile, encoding: .utf8).split(separator: "\n").map(String.init) }
    }

    var leftoverTempDirs: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: downloads.path)) ?? [])
            .filter { $0.hasPrefix(".sunshine-dl-") }
    }
}

func collect(_ stream: AsyncThrowingStream<DownloadUpdate, Error>) async -> (updates: [DownloadUpdate], error: Error?) {
    var updates: [DownloadUpdate] = []
    do {
        for try await u in stream { updates.append(u) }
        return (updates, nil)
    } catch {
        return (updates, error)
    }
}

let zooURL = "https://www.youtube.com/watch?v=jNQXAC9IVRw"

@Suite struct DownloadServiceArgumentTests {
    @Test func argvMatchesPlan() {
        let args = DownloadService.arguments(
            videoID: "jNQXAC9IVRw",
            ffmpeg: URL(fileURLWithPath: "/A/Sunshine.app/Contents/Helpers/ffmpeg"),
            deno: URL(fileURLWithPath: "/A/Sunshine.app/Contents/Helpers/deno"),
            downloads: URL(fileURLWithPath: "/Users/me/Downloads"),
            tempDir: URL(fileURLWithPath: "/Users/me/Downloads/.sunshine-dl-X"))
        #expect(args == [
            "--no-playlist", "--playlist-items", "1", "--match-filter", "!is_live",
            "--newline", "--progress", "--no-simulate", "--no-quiet",
            "-f", "bv*[ext=mp4][vcodec^=avc1][height<=1080]+ba[ext=m4a]/b[ext=mp4][height<=1080]",
            "--merge-output-format", "mp4",
            "--ffmpeg-location", "/A/Sunshine.app/Contents/Helpers/ffmpeg",
            "--js-runtimes", "deno:/A/Sunshine.app/Contents/Helpers/deno",
            "-P", "home:/Users/me/Downloads",
            "-P", "temp:/Users/me/Downloads/.sunshine-dl-X",
            "-o", "%(title).120B [%(id)s].%(ext)s",
            "--progress-template",
            "download:SUNSHINE|%(progress.status)s|%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s|%(info.vcodec)s",
            "--print", "after_move:SUNSHINE_FILE|%(filepath)s",
            "--", "https://www.youtube.com/watch?v=jNQXAC9IVRw",
        ])
        #expect(!args.contains { $0.contains("~") })
    }

    @Test func labels() {
        #expect(DownloadService.label(phase: .video, fraction: 0.425) == "Downloading video — 42%")
        #expect(DownloadService.label(phase: .audio, fraction: 0.8) == "Downloading audio — 80%")
        #expect(DownloadService.label(phase: .audio, fraction: 1) == "Downloading audio — 100%")
        #expect(DownloadService.label(phase: .unknown, fraction: 0.1) == "Downloading — 10%")
        #expect(DownloadService.label(phase: .video, fraction: nil) == "Downloading video…")
    }

    @Test func nonVideoLinksAreRejectedWithoutLookingUpHelpers() async throws {
        let log = LocateLog()
        let service = DownloadService(downloadsDirectory: FileManager.default.temporaryDirectory) { helper in
            log.append(helper)
            throw BinaryLocatorError.notFound(helper)
        }
        for bad in ["https://www.youtube.com/playlist?list=PL123", "https://www.youtube.com/@name",
                    "https://vimeo.com/123", "-o /etc/passwd", ""] {
            let (updates, error) = await collect(await service.start(urlString: bad))
            #expect(updates.isEmpty)
            #expect(error as? DownloadError == .invalidURL, "\(bad)")
            #expect(error?.localizedDescription == "Paste a single video link.")
        }
        #expect(log.helpers.isEmpty)
    }

    @Test func missingHelperFailsBeforeSpawn() async throws {
        let dir = try TempDir()
        let service = DownloadService(downloadsDirectory: dir.url) { throw BinaryLocatorError.notFound($0) }
        let (_, error) = await collect(await service.start(urlString: zooURL))
        #expect(error as? BinaryLocatorError == .notFound(.ytdlp))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.url.path).isEmpty)
    }
}

extension ProcessSpawningTests {
    @Suite struct DownloadServiceTests {
        @Test func successfulDownloadReportsPhasesAndFile() async throws {
            let fake = try FakeYTDLP(body: """
            echo "[youtube] Extracting URL: https://www.youtube.com/watch?v=jNQXAC9IVRw"
            echo "SUNSHINE|downloading|50|100|NA|avc1.4d400c"
            echo "SUNSHINE|finished|100|100|NA|avc1.4d400c"
            echo "SUNSHINE|downloading|40|NA|80.0|none"
            echo "SUNSHINE|finished|80|80|NA|none"
            echo '[Merger] Merging formats into "x.mp4"'
            sleep 2.5
            touch "$H/Me at the zoo [jNQXAC9IVRw].mp4"
            echo "SUNSHINE_FILE|$H/Me at the zoo [jNQXAC9IVRw].mp4"
            """)
            // The 2.5 s silent merge must not trip a 1 s watchdog: it's suspended at [Merger].
            // (The script's other lines print back to back, far inside 1 s.)
            let service = fake.service(inactivity: .seconds(1))
            let (updates, error) = await collect(await service.start(urlString: zooURL + "&list=PLx&t=30"))
            #expect(error == nil)
            let file = fake.downloads.appendingPathComponent("Me at the zoo [jNQXAC9IVRw].mp4")
            #expect(updates == [
                .progress(label: "Fetching video info…", fraction: nil),
                .progress(label: "Downloading video — 50%", fraction: 0.5),
                .progress(label: "Downloading video — 100%", fraction: 1),
                .progress(label: "Downloading audio — 50%", fraction: 0.5),
                .progress(label: "Downloading audio — 100%", fraction: 1),
                .progress(label: "Merging…", fraction: nil),
                .completed(file),
            ])
            #expect(fake.leftoverTempDirs.isEmpty)

            let argv = try fake.recordedArgv
            #expect(argv.last == zooURL, "canonical URL, playlist params stripped")
            let tempArg = try #require(argv.first { $0.hasPrefix("temp:") })
            let tempDir = URL(fileURLWithPath: String(tempArg.dropFirst("temp:".count)))
            #expect(tempDir.deletingLastPathComponent().standardizedFileURL == fake.downloads.standardizedFileURL)
            #expect(argv == DownloadService.arguments(
                videoID: "jNQXAC9IVRw", ffmpeg: fake.script.deletingLastPathComponent().appendingPathComponent("ffmpeg"),
                deno: fake.script.deletingLastPathComponent().appendingPathComponent("deno"),
                downloads: fake.downloads, tempDir: tempDir))
            #expect(Set(fake.log.helpers) == Set(Helper.allCases))
        }

        @Test func alreadyDownloadedCountsAsCompleted() async throws {
            let fake = try FakeYTDLP(body: """
            echo "[download] $H/Me at the zoo [jNQXAC9IVRw].mp4 has already been downloaded"
            """)
            let (updates, error) = await collect(await fake.service().start(urlString: zooURL))
            #expect(error == nil)
            #expect(updates == [.progress(label: "Fetching video info…", fraction: nil),
                                .completed(fake.downloads.appendingPathComponent("Me at the zoo [jNQXAC9IVRw].mp4"))])
        }

        @Test func cancelKillsTheTreeAndRemovesTempDir() async throws {
            let fake = try FakeYTDLP(body: """
            echo "SUNSHINE|downloading|30|100|NA|avc1.4d400c"
            echo partial > "$T/video.f137.mp4.part"
            sleep 100 & sleep 100
            """)
            let service = fake.service()
            let stream = await service.start(urlString: zooURL)
            var iterator = stream.makeAsyncIterator()
            #expect(try await iterator.next() == .progress(label: "Fetching video info…", fraction: nil))
            let first = try await iterator.next()
            #expect(first == .progress(label: "Downloading video — 30%", fraction: 0.3))
            #expect(fake.leftoverTempDirs.count == 1)
            let pgid = try #require(pid_t(String(contentsOf: fake.pidFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)))

            let cancelled = ContinuousClock.now
            await service.cancel()
            await #expect(throws: CancellationError.self) { _ = try await iterator.next() }
            #expect(ContinuousClock.now - cancelled < .seconds(3))
            #expect(try await processes(inGroup: pgid).isEmpty)
            #expect(fake.leftoverTempDirs.isEmpty)
            #expect(try FileManager.default.contentsOfDirectory(atPath: fake.downloads.path).isEmpty)

            // cancel() returned only after teardown: nothing is left to poll for.
            let again = await service.start(urlString: "https://youtu.be/aaaaaaaaaaa")
            await service.cancel()
            let (_, againError) = await collect(again)
            #expect(againError is CancellationError)
        }

        @Test func cancelWaitsForAChildThatIgnoresSIGTERM() async throws {
            let fake = try FakeYTDLP(body: """
            trap '' TERM
            echo "SUNSHINE|downloading|30|100|NA|avc1.4d400c"
            while true; do sleep 0.1; done
            """)
            let service = fake.service()
            var iterator = await service.start(urlString: zooURL).makeAsyncIterator()
            _ = try await iterator.next()  // Fetching video info…
            _ = try await iterator.next()  // 30%
            let pgid = try #require(pid_t(String(contentsOf: fake.pidFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)))

            let start = ContinuousClock.now
            await service.cancel()
            let took = ContinuousClock.now - start
            #expect(took >= .seconds(1.5) && took < .seconds(4), "SIGKILL follows SIGTERM after 2 s: \(took)")
            #expect(try await processes(inGroup: pgid).isEmpty)
            #expect(fake.leftoverTempDirs.isEmpty)
            await #expect(throws: CancellationError.self) { _ = try await iterator.next() }
        }

        @Test func startRightAfterUnawaitedCancelWaitsInsteadOfFailing() async throws {
            let fake = try FakeYTDLP(body: "trap '' TERM\necho 'SUNSHINE|downloading|1|100|NA|avc1'\nwhile true; do sleep 0.1; done\n")
            let service = fake.service()
            var iterator = await service.start(urlString: zooURL).makeAsyncIterator()
            _ = try await iterator.next()
            _ = try await iterator.next()

            // Like the UI: fire-and-forget cancel, then Download again immediately.
            let cancelling = Task { await service.cancel() }
            while !(await service.isCancellingForTesting) { await Task.yield() }
            let again = await service.start(urlString: zooURL)
            await cancelling.value
            await #expect(throws: CancellationError.self) { _ = try await iterator.next() }

            var next = again.makeAsyncIterator()
            let first = try await next.next()
            #expect(first == .progress(label: "Fetching video info…", fraction: nil), "second start must not be alreadyRunning")
            await service.cancel()
        }

        @Test func cancellingTheConsumerCancelsTheDownload() async throws {
            let fake = try FakeYTDLP(body: "echo 'SUNSHINE|downloading|1|100|NA|avc1'\nsleep 100\n")
            let service = fake.service()
            let consumer = Task { await collect(await service.start(urlString: zooURL)) }
            while (try? String(contentsOf: fake.pidFile, encoding: .utf8)) == nil {
                try await Task.sleep(for: .milliseconds(20))
            }
            let pgid = try #require(pid_t(String(contentsOf: fake.pidFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)))
            consumer.cancel()
            // A cancelled `for try await` ends without a file (or with CancellationError).
            let (updates, error) = await consumer.value
            #expect(error == nil || error is CancellationError)
            #expect(!updates.contains { if case .completed = $0 { true } else { false } })
            var gone = false
            for _ in 0..<150 {
                if try await processes(inGroup: pgid).isEmpty, fake.leftoverTempDirs.isEmpty { gone = true; break }
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(gone, "yt-dlp still running or temp dir left 3 s after the consumer was cancelled")
        }

        @Test func secondStartWhileRunningIsRejected() async throws {
            let fake = try FakeYTDLP(body: "sleep 100\n")
            let service = fake.service()
            let first = await service.start(urlString: zooURL)
            let (_, error) = await collect(await service.start(urlString: zooURL))
            #expect(error as? DownloadError == .alreadyRunning)
            await service.cancel()
            let (_, firstError) = await collect(first)
            #expect(firstError is CancellationError)
        }

        @Test func errorLinesMapToReadableErrors() async throws {
            let cases: [(String, DownloadError)] = [
                ("echo 'ERROR: [youtube] aaaaaaaaaaa: Video unavailable. This video is unavailable' >&2; exit 1", .unavailable),
                ("echo \"ERROR: [youtube] x: Unable to download API page: <urlopen error [Errno 8] nodename nor servname provided>\" >&2; exit 1", .network),
                ("echo 'ERROR: [youtube] x: Unable to extract initial player response; please report this issue' >&2; exit 1", .outdated),
                ("echo '[download] Stream 24/7 does not pass filter (!is_live), skipping ..'", .liveStream),
                ("echo 'WARNING: something' >&2; exit 0", .noOutputFile(stderrTail: "WARNING: something")),
                ("echo 'a' >&2; echo 'b' >&2; echo 'c' >&2; echo 'd' >&2; echo 'e' >&2; echo 'f' >&2; exit 2",
                 .failed(stderrTail: "b\nc\nd\ne\nf")),
                ("echo 'ERROR: Requested format is not available' >&2; exit 1",
                 .failed(stderrTail: "ERROR: Requested format is not available")),
            ]
            for (body, expected) in cases {
                let fake = try FakeYTDLP(body: body + "\n")
                let (updates, error) = await collect(await fake.service().start(urlString: zooURL))
                #expect(updates == [.progress(label: "Fetching video info…", fraction: nil)])
                #expect(error as? DownloadError == expected, "\(body)")
                #expect(fake.leftoverTempDirs.isEmpty)
            }
        }

        @Test func permissionErrorsAreClassifiable() async throws {
            let fake = try FakeYTDLP(body: """
            echo "ERROR: unable to open for writing: [Errno 1] Operation not permitted: '$HOME/Downloads/x.mp4'" >&2
            exit 1
            """)
            let (_, error) = await collect(await fake.service().start(urlString: zooURL))
            let posix = try #require(error as? POSIXError)
            #expect(posix.code == .EPERM)
            let home = FileManager.default.homeDirectoryForCurrentUser
            #expect(FileAccessError.classify(posix, path: home.appendingPathComponent("Downloads/x.mp4"))
                == .tccDenied(.downloads))
        }

        @Test func permissionErrorsOutsideProtectedFoldersStayGeneric() async throws {
            let line = "ERROR: unable to open for writing: [Errno 13] Permission denied: '/private/tmp/x.mp4'"
            let fake = try FakeYTDLP(body: "echo \"\(line)\" >&2\nexit 1\n")
            let (_, error) = await collect(await fake.service().start(urlString: zooURL))
            // Not a TCC denial: a plain yt-dlp failure showing the stderr tail.
            #expect(error as? DownloadError == .failed(stderrTail: line))
            #expect(DownloadService.tccError(String(line.dropFirst("ERROR: ".count))) == nil)
        }

        @Test func watchdogEndsASilentDownload() async throws {
            let fake = try FakeYTDLP(body: "echo '[youtube] Extracting URL: x'\nsleep 100\n")
            let start = ContinuousClock.now
            let (_, error) = await collect(await fake.service(inactivity: .milliseconds(500)).start(urlString: zooURL))
            #expect(error as? DownloadError == .timedOut)
            #expect(ContinuousClock.now - start < .seconds(5))
            #expect(fake.leftoverTempDirs.isEmpty)
        }
    }
}

@Suite struct DownloadServiceTCCMappingTests {
    let home = URL(fileURLWithPath: "/Users/tester")

    @Test func permissionErrorsInsideProtectedFoldersMapToPOSIX() {
        #expect(DownloadService.tccError("unable to open for writing: [Errno 1] Operation not permitted: '/Users/tester/Downloads/a b.mp4'", home: home)?.code == .EPERM)
        #expect(DownloadService.tccError("[Errno 13] Permission denied: \"/Users/tester/Desktop/x.mp4\"", home: home)?.code == .EACCES)
    }

    @Test func otherMessagesDoNotMap() {
        #expect(DownloadService.tccError("[Errno 1] Operation not permitted: '/private/tmp/x.mp4'", home: home) == nil)
        #expect(DownloadService.tccError("Permission denied (publickey)", home: home) == nil)
        #expect(DownloadService.tccError("Operation not permitted", home: home) == nil)
        #expect(DownloadService.tccError("[Errno 2] No such file or directory: '/Users/tester/Downloads/x'", home: home) == nil)
    }
}
