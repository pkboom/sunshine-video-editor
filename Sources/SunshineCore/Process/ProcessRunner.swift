import Darwin
import Foundation
import Synchronization

public enum ProcessRunnerError: Error, Equatable, Sendable {
    /// `posix_spawn` failed; `errno` is its return value (e.g. EACCES, EPERM, ENOENT).
    case spawnFailed(executable: String, errno: Int32)
    /// No stdout/stderr bytes for the configured inactivity interval while the watchdog was armed.
    case watchdogTimeout(inactivity: Duration)
    /// The child was killed by a signal it didn't get from `cancel()` or the watchdog.
    case terminatedBySignal(Int32)
    /// `run` was called while a previous `run` on the same runner was still active.
    case alreadyRunning
}

/// Runs one child process at a time (plan §2(d), option D2: `posix_spawn`).
///
/// - The child leads a new process group, so `cancel()` and the watchdog signal the
///   whole tree (yt-dlp → ffmpeg, PyInstaller bootloader → Python) with `killpg`.
/// - Only fds 0/1/2 are inherited (`POSIX_SPAWN_CLOEXEC_DEFAULT`); stdin is `/dev/null`.
/// - stdout and stderr are drained concurrently, so neither pipe can fill up and block the child.
/// - The environment is minimal unless the caller passes one (`minimalEnvironment()`).
///
/// Lines are split on `\n` and `\r`; empty lines are dropped. Line callbacks run on
/// background threads, stdout and stderr concurrently, in order within each stream.
public final class ProcessRunner: Sendable {
    private struct State {
        var running = false
        var pid: pid_t?
        /// Bumped per run, so a delayed SIGKILL never reaches a later run's child.
        var generation = 0
        var exited = false
        var cancelled = false
        var timedOut = false
        var inactivity: Duration?
        var watchdogSuspended = false
        var lastActivity = ContinuousClock.now
    }

    private let state = Mutex(State())

    public init() {}

    /// `PATH=/usr/bin:/bin`, plus `HOME`, `TMPDIR` and `LANG` from this process (LANG defaults to en_US.UTF-8).
    public static func minimalEnvironment() -> [String: String] {
        let env = ProcessInfo.processInfo.environment
        var result = ["PATH": "/usr/bin:/bin", "LANG": env["LANG"] ?? "en_US.UTF-8"]
        result["HOME"] = env["HOME"] ?? NSHomeDirectory()
        result["TMPDIR"] = env["TMPDIR"] ?? NSTemporaryDirectory()
        return result
    }

    /// The running child's pid, which is also its process group id.
    public var processIdentifier: pid_t? {
        state.withLock { $0.running ? $0.pid : nil }
    }

    /// Arms (or with nil disarms) the inactivity watchdog: if no stdout/stderr bytes arrive for
    /// `inactivity` while it's armed and not suspended, the process group is killed and `run`
    /// throws `.watchdogTimeout`. Applies to the current and later runs.
    public func watchdog(inactivity: Duration?) {
        state.withLock {
            $0.inactivity = inactivity
            $0.lastActivity = .now
        }
    }

    /// Pauses the watchdog, e.g. while ffmpeg merges silently.
    public func suspendWatchdog() {
        state.withLock { $0.watchdogSuspended = true }
    }

    /// Re-arms the watchdog; the inactivity interval restarts now.
    public func resumeWatchdog() {
        state.withLock {
            $0.watchdogSuspended = false
            $0.lastActivity = .now
        }
    }

    /// Kills the process group: SIGTERM, then SIGKILL after 2 s. `run` throws `CancellationError`.
    /// Calling it before `run` makes the next `run` throw without spawning.
    public func cancel() {
        let pid: pid_t? = state.withLock {
            $0.cancelled = true
            return $0.running ? $0.pid : nil
        }
        if let pid { terminateGroup(pid) }
    }

    /// Spawns `executable` (no shell, no PATH lookup) and returns its exit status once it has
    /// exited and both pipes reached EOF. Throws `CancellationError` after `cancel()` or task
    /// cancellation. `env` nil means `minimalEnvironment()`.
    public func run(
        executable: URL,
        args: [String],
        env: [String: String]? = nil,
        onStdoutLine: @escaping @Sendable (String) -> Void = { _ in },
        onStderrLine: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> Int32 {
        let isTaskCancelled = Task.isCancelled
        try state.withLock {
            guard !$0.running else { throw ProcessRunnerError.alreadyRunning }
            if $0.cancelled || isTaskCancelled {
                // Consume the pending cancel; the runner is never marked running here.
                $0.cancelled = false
                throw CancellationError()
            }
            $0.running = true
            $0.generation += 1
            $0.pid = nil
            $0.exited = false
            $0.timedOut = false
            $0.lastActivity = .now
        }
        defer { state.withLock { $0.running = false; $0.cancelled = false } }

        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                do {
                    try spawnAndCollect(executable: executable, args: args,
                                        env: env ?? Self.minimalEnvironment(),
                                        onStdoutLine: onStdoutLine, onStderrLine: onStderrLine) {
                        continuation.resume(returning: $0)
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            cancel()
        }

        let (cancelled, timedOut, inactivity) = state.withLock { ($0.cancelled, $0.timedOut, $0.inactivity) }
        if timedOut { throw ProcessRunnerError.watchdogTimeout(inactivity: inactivity ?? .zero) }
        if cancelled { throw CancellationError() }
        if Self.wasSignaled(status) { throw ProcessRunnerError.terminatedBySignal(status & 0x7f) }
        return (status >> 8) & 0xff
    }

    // MARK: - Spawning

    private func spawnAndCollect(
        executable: URL,
        args: [String],
        env: [String: String],
        onStdoutLine: @escaping @Sendable (String) -> Void,
        onStderrLine: @escaping @Sendable (String) -> Void,
        completion: @escaping @Sendable (Int32) -> Void
    ) throws {
        var outPipe: [Int32] = [-1, -1]
        var errPipe: [Int32] = [-1, -1]
        guard pipe(&outPipe) == 0 else { throw ProcessRunnerError.spawnFailed(executable: executable.path, errno: errno) }
        guard pipe(&errPipe) == 0 else {
            let e = errno
            close(outPipe[0]); close(outPipe[1])
            throw ProcessRunnerError.spawnFailed(executable: executable.path, errno: e)
        }
        // Keep these out of children spawned concurrently by other code in this process.
        for fd in outPipe + errPipe { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF
        posix_spawnattr_setflags(&attr, Int16(flags))
        posix_spawnattr_setpgroup(&attr, 0)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attr, &noSignals)
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigdefault(&attr, &allSignals)

        let path = executable.path
        let argv = ([path] + args).map { strdup($0) } + [nil]
        let envp = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, path, &actions, &attr, argv, envp)
        // The child has its own copies of the write ends; ours must close so EOF can arrive.
        close(outPipe[1])
        close(errPipe[1])
        guard rc == 0 else {
            close(outPipe[0])
            close(errPipe[0])
            throw ProcessRunnerError.spawnFailed(executable: path, errno: rc)
        }

        let cancelledBeforeSpawn = state.withLock {
            $0.pid = pid
            $0.lastActivity = .now
            return $0.cancelled
        }
        if cancelledBeforeSpawn { terminateGroup(pid) }

        let (outRead, errRead, childPID) = (outPipe[0], errPipe[0], pid)
        let group = DispatchGroup()
        let status = Mutex<Int32>(0)
        let markActivity: @Sendable () -> Void = { [self] in state.withLock { $0.lastActivity = .now } }

        group.enter()
        DispatchQueue.global(qos: .utility).async {
            Self.drain(fd: outRead, onActivity: markActivity, onLine: onStdoutLine)
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            Self.drain(fd: errRead, onActivity: markActivity, onLine: onStderrLine)
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            // Wait for exit without reaping: while the leader is a zombie its pid (= the group id)
            // can't be reused, so every killpg below and in terminateGroup hits our group only.
            var info = siginfo_t()
            while waitid(P_PID, id_t(childPID), &info, WEXITED | WNOWAIT) == -1 && errno == EINTR {}
            state.withLock {
                $0.exited = true
                // Strays left in the group would hold the pipes open and block EOF forever.
                killpg(childPID, SIGKILL)
            }
            var raw: Int32 = 0
            while waitpid(childPID, &raw, 0) == -1 && errno == EINTR {}
            status.withLock { $0 = raw }
            group.leave()
        }

        let watchdog = Task.detached { [self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                let fire: Bool = state.withLock {
                    guard !$0.exited, !$0.timedOut, !$0.watchdogSuspended, let limit = $0.inactivity else { return false }
                    if ContinuousClock.now - $0.lastActivity >= limit {
                        $0.timedOut = true
                        return true
                    }
                    return false
                }
                if fire { terminateGroup(childPID) }
            }
        }

        group.notify(queue: .global(qos: .utility)) {
            watchdog.cancel()
            completion(status.withLock { $0 })
        }
    }

    /// SIGTERM the group now, SIGKILL it after 2 s. Signals are sent under the lock and only
    /// while the leader hasn't been reaped (`exited` is set before reaping), so a reused pid
    /// is never signalled.
    private func terminateGroup(_ pid: pid_t) {
        let generation = state.withLock { $0.generation }
        signalGroup(pid, SIGTERM, generation: generation)
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [self] in
            signalGroup(pid, SIGKILL, generation: generation)
        }
    }

    private func signalGroup(_ pid: pid_t, _ signal: Int32, generation: Int) {
        state.withLock {
            if $0.generation == generation, $0.pid == pid, !$0.exited { killpg(pid, signal) }
        }
    }

    private static func wasSignaled(_ status: Int32) -> Bool {
        let sig = status & 0x7f
        return sig != 0 && sig != 0x7f
    }

    /// Blocking read loop until EOF; closes `fd`.
    private static func drain(fd: Int32, onActivity: @Sendable () -> Void, onLine: @Sendable (String) -> Void) {
        defer { close(fd) }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var pending: [UInt8] = []
        func flush() {
            if !pending.isEmpty {
                onLine(String(decoding: pending, as: UTF8.self))
                pending.removeAll(keepingCapacity: true)
            }
        }
        while true {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n < 0 {
                if errno == EINTR { continue }
                break
            }
            if n == 0 { break }
            onActivity()
            for byte in buffer[0..<n] {
                if byte == 0x0A || byte == 0x0D {
                    flush()
                } else {
                    pending.append(byte)
                }
            }
        }
        flush()
    }
}
