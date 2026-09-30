import Foundation

public enum DownloadUpdate: Sendable, Equatable {
    /// `fraction` nil means indeterminate (e.g. "Merging…").
    case progress(label: String, fraction: Double?)
    case completed(URL)
}

public enum DownloadError: Error, Equatable, Sendable, LocalizedError {
    case invalidURL
    case alreadyRunning
    case unavailable
    case network
    case outdated
    case liveStream
    case timedOut
    /// yt-dlp exited 0 without reporting a file.
    case noOutputFile(stderrTail: String)
    /// Any other yt-dlp failure; carries the last stderr lines.
    case failed(stderrTail: String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL: "Paste a single video link."
        case .alreadyRunning: "A download is already running."
        case .unavailable: "Video unavailable."
        case .network: "Network error. Check your internet connection and try again."
        case .outdated: "yt-dlp may be outdated — place a newer yt-dlp in ~/Library/Application Support/Sunshine/bin"
        case .liveStream: "Live streams aren't supported."
        case .timedOut: "yt-dlp stopped responding. Check your internet connection and try again."
        case .noOutputFile(let tail): tail.isEmpty ? "yt-dlp finished without saving a video." : "yt-dlp finished without saving a video.\n\(tail)"
        case .failed(let tail): tail.isEmpty ? "yt-dlp failed." : tail
        }
    }
}

/// Downloads one YouTube video with the bundled yt-dlp into ~/Downloads (plan S3).
///
/// Each job gets its own temp dir `<Downloads>/.sunshine-dl-<uuid>/` (yt-dlp `-P temp:`); the final
/// file only appears in Downloads after yt-dlp's move, so cancel just kills the process group and
/// removes that dir. A 60 s inactivity watchdog runs until yt-dlp starts post-processing.
///
/// Permission failures in Downloads are thrown as Cocoa/POSIX permission errors so
/// `FileAccessError.classify(_:path:)` can recognize a TCC denial.
public actor DownloadService {
    private let downloadsDirectory: URL?
    private let inactivityLimit: Duration
    private let locate: @Sendable (Helper) throws -> URL
    private var job: Job?

    private struct Job {
        let id: UUID
        let runner: ProcessRunner
        let task: Task<Void, Never>
        var cancelling = false
    }

    /// `downloadsDirectory` nil means the user's Downloads folder.
    public init(downloadsDirectory: URL? = nil,
                inactivityLimit: Duration = .seconds(60),
                locate: @escaping @Sendable (Helper) throws -> URL = { try BinaryLocator.url(for: $0) }) {
        self.downloadsDirectory = downloadsDirectory
        self.inactivityLimit = inactivityLimit
        self.locate = locate
    }

    /// Validates `urlString` (no process is spawned for anything but a single video link), then
    /// streams labeled progress and finally `.completed(file)`. Cancelling the consuming task or
    /// calling `cancel()` ends the stream with `CancellationError`.
    ///
    /// If the previous job is being cancelled, this waits for its teardown first; a job that is
    /// still running (not cancelled) makes the stream fail with `.alreadyRunning`.
    public func start(urlString: String) async -> AsyncThrowingStream<DownloadUpdate, Error> {
        let (stream, continuation) = AsyncThrowingStream<DownloadUpdate, Error>.makeStream()
        guard let videoID = YouTubeURL.videoID(from: urlString) else {
            continuation.finish(throwing: DownloadError.invalidURL)
            return stream
        }
        while let previous = job, previous.cancelling {
            await previous.task.value
        }
        guard job == nil else {
            continuation.finish(throwing: DownloadError.alreadyRunning)
            return stream
        }

        let id = UUID()
        let runner = ProcessRunner()
        let downloads = downloadsDirectory
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let (locate, limit) = (self.locate, inactivityLimit)
        let task = Task.detached {
            let result = await Self.perform(videoID: videoID, downloads: downloads, jobID: id, inactivityLimit: limit,
                                            runner: runner, locate: locate, continuation: continuation)
            // Free the service before the consumer sees the end, so it can start again right away.
            await self.finished(id)
            switch result {
            case .success(let file):
                continuation.yield(.completed(file))
                continuation.finish()
            case .failure(let error):
                continuation.finish(throwing: error)
            }
        }
        job = Job(id: id, runner: runner, task: task)
        continuation.onTermination = { reason in
            if case .cancelled = reason { Task { await self.cancel(jobID: id) } }
        }
        return stream
    }

    /// Kills yt-dlp and its children and returns once the job is torn down: the process group
    /// is gone (SIGTERM, SIGKILL after 2 s at most), the temp dir is removed, and the service
    /// accepts a new `start`. The job's stream ends with `CancellationError`.
    public func cancel() async {
        guard var current = job else { return }
        current.cancelling = true
        job = current
        current.runner.cancel()
        await current.task.value
    }

    /// The consumer stopped iterating: cancel that job (only if it's still the current one).
    private func cancel(jobID: UUID) async {
        if job?.id == jobID { await cancel() }
    }

    /// True while a job is being cancelled (tests use it to hit the start-during-teardown path).
    var isCancellingForTesting: Bool { job?.cancelling == true }

    private func finished(_ id: UUID) {
        if job?.id == id { job = nil }
    }

    // MARK: - Job

    private static func perform(videoID: String, downloads: URL, jobID: UUID, inactivityLimit: Duration,
                                runner: ProcessRunner,
                                locate: @Sendable (Helper) throws -> URL,
                                continuation: AsyncThrowingStream<DownloadUpdate, Error>.Continuation) async -> Result<URL, Error> {
        let tempDir = downloads.appendingPathComponent(
            StaleFileSweeper.downloadTempPrefix + jobID.uuidString, isDirectory: true)
        let result: Result<URL, Error>
        // Before the first write to Downloads, which can block on the TCC prompt; after that,
        // extraction and the Deno JS challenge take ~10 s before the first progress line.
        continuation.yield(.progress(label: "Fetching video info…", fraction: nil))
        do {
            let ytdlp = try locate(.ytdlp)
            let ffmpeg = try locate(.ffmpeg)
            let deno = try locate(.deno)
            // Creating the dir is the app's own first write to Downloads, so the TCC prompt
            // (and any denial) happens here rather than inside yt-dlp.
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

            let args = arguments(videoID: videoID, ffmpeg: ffmpeg, deno: deno,
                                 downloads: downloads, tempDir: tempDir)
            result = .success(try await run(ytdlp: ytdlp, args: args, runner: runner,
                                            inactivityLimit: inactivityLimit, continuation: continuation))
        } catch {
            result = .failure(error)
        }
        // The process group is dead by now, so nothing writes into the temp dir any more.
        try? FileManager.default.removeItem(at: tempDir)
        return result
    }

    /// The exact yt-dlp argv from plan S3, plus `--no-quiet`: `--print` implies quiet mode, which
    /// would hide the `[Merger]`, "already downloaded" and match-filter lines the parser needs.
    public static func arguments(videoID: String, ffmpeg: URL, deno: URL, downloads: URL, tempDir: URL) -> [String] {
        [
            "--no-playlist", "--playlist-items", "1", "--match-filter", "!is_live",
            "--newline", "--progress", "--no-simulate", "--no-quiet",
            "-f", "bv*[ext=mp4][vcodec^=avc1][height<=1080]+ba[ext=m4a]/b[ext=mp4][height<=1080]",
            "--merge-output-format", "mp4",
            "--ffmpeg-location", ffmpeg.path,
            "--js-runtimes", "deno:\(deno.path)",
            "-P", "home:\(downloads.path)",
            "-P", "temp:\(tempDir.path)",
            "-o", "%(title).120B [%(id)s].%(ext)s",
            "--progress-template",
            "download:SUNSHINE|%(progress.status)s|%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s|%(info.vcodec)s",
            "--print", "after_move:SUNSHINE_FILE|%(filepath)s",
            "--", YouTubeURL.canonicalURL(id: videoID).absoluteString,
        ]
    }

    private enum Line: Sendable {
        case stdout(String)
        case stderr(String)
    }

    private static func run(ytdlp: URL, args: [String], runner: ProcessRunner, inactivityLimit: Duration,
                            continuation: AsyncThrowingStream<DownloadUpdate, Error>.Continuation) async throws -> URL {
        // Lines arrive on two reader threads; one consumer keeps the parser single-threaded.
        let (lines, sink) = AsyncStream<Line>.makeStream()
        let consumer = Task { () -> Outcome in
            var outcome = Outcome()
            var parser = YTDLPOutputParser()
            for await line in lines {
                let text: String
                switch line {
                case .stdout(let s): text = s
                case .stderr(let s):
                    text = s
                    outcome.stderrTail.append(s)
                    if outcome.stderrTail.count > 5 { outcome.stderrTail.removeFirst() }
                }
                outcome.producedOutput = true
                switch parser.consume(line: text) {
                case .progress(let phase, let fraction)?:
                    if !parser.isPostProcessing {
                        continuation.yield(.progress(label: label(phase: phase, fraction: fraction), fraction: fraction))
                    }
                case .merging?:
                    runner.suspendWatchdog()
                    continuation.yield(.progress(label: "Merging…", fraction: nil))
                case .completed(let path)?:
                    outcome.path = path
                case .error(let kind, let message)?:
                    outcome.error = (kind, message)
                case nil:
                    break
                }
            }
            return outcome
        }

        runner.watchdog(inactivity: inactivityLimit)
        let status: Int32
        do {
            status = try await runner.run(
                executable: ytdlp, args: args,
                onStdoutLine: { sink.yield(.stdout($0)) },
                onStderrLine: { sink.yield(.stderr($0)) })
            sink.finish()
        } catch {
            sink.finish()
            let outcome = await consumer.value
            if case ProcessRunnerError.watchdogTimeout = error { throw DownloadError.timedOut }
            throw BinaryLocator.classifyLaunchFailure(error, helper: .ytdlp, producedOutput: outcome.producedOutput)
        }
        let outcome = await consumer.value
        let tail = outcome.stderrTail.joined(separator: "\n")

        if status == 0, let path = outcome.path {
            return URL(fileURLWithPath: path)
        }
        if let (kind, message) = outcome.error {
            throw mapError(kind, message: message, tail: tail)
        }
        throw status == 0 ? DownloadError.noOutputFile(stderrTail: tail) : DownloadError.failed(stderrTail: tail)
    }

    private struct Outcome: Sendable {
        var path: String?
        var error: (DownloadErrorKind, String)?
        var stderrTail: [String] = []
        var producedOutput = false
    }

    private static func mapError(_ kind: DownloadErrorKind, message: String, tail: String) -> Error {
        if let permission = tccError(message) { return permission }
        return switch kind {
        case .unavailable: DownloadError.unavailable
        case .network: DownloadError.network
        case .outdated: DownloadError.outdated
        case .liveStream: DownloadError.liveStream
        case .generic: DownloadError.failed(stderrTail: tail.isEmpty ? message : tail)
        }
    }

    /// A yt-dlp permission failure ("[Errno 1] Operation not permitted: '<path>'") on a path inside
    /// Downloads/Desktop/Documents, as a POSIX error `FileAccessError.classify` maps to `.tccDenied`.
    /// Permission errors elsewhere stay ordinary yt-dlp failures.
    static func tccError(_ message: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> POSIXError? {
        let code: POSIXErrorCode
        if message.contains("Operation not permitted") {
            code = .EPERM
        } else if message.contains("Permission denied") {
            code = .EACCES
        } else {
            return nil
        }
        let error = POSIXError(code)
        for path in quotedPaths(in: message) {
            if case .tccDenied = FileAccessError.classify(error, path: URL(fileURLWithPath: path), home: home) {
                return error
            }
        }
        return nil
    }

    /// Absolute paths in single or double quotes, as Python prints them in OSError messages.
    private static func quotedPaths(in message: String) -> [String] {
        var paths: [String] = []
        for quote in ["'", "\""] {
            let parts = message.components(separatedBy: quote)
            // Odd-indexed parts are inside quotes.
            for (i, part) in parts.enumerated() where i % 2 == 1 && part.hasPrefix("/") {
                paths.append(part)
            }
        }
        return paths
    }

    static func label(phase: DownloadPhase, fraction: Double?) -> String {
        let what = switch phase {
        case .video: "Downloading video"
        case .audio: "Downloading audio"
        case .unknown: "Downloading"
        }
        guard let fraction else { return "\(what)…" }
        return "\(what) — \(Int((fraction * 100).rounded(.down)))%"
    }
}
