import Foundation

public enum YTDLPEvent: Sendable, Equatable {
    /// `fraction` is nil when progress is indeterminate.
    case progress(phase: DownloadPhase, fraction: Double?)
    /// A `[Merger]`/`[Fixup…]` post-processor started; ffmpeg may be silent, so the watchdog must suspend.
    case merging
    /// From `SUNSHINE_FILE|<path>` or `[download] <path> has already been downloaded`.
    case completed(path: String)
    case error(DownloadErrorKind, message: String)
}

public enum DownloadPhase: Sendable, Equatable { case video, audio, unknown }

public enum DownloadErrorKind: Sendable, Equatable { case unavailable, network, outdated, liveStream, generic }

/// Turns yt-dlp output lines (stdout and stderr) into events. Expects the argv from plan S3,
/// with `--no-quiet` so `[Merger]`, "already downloaded" and match-filter lines are printed:
/// `--print` alone implies quiet mode, which suppresses them.
public struct YTDLPOutputParser: Sendable {
    /// The last completed path seen, if any.
    public private(set) var completedPath: String?
    /// True once a post-processing line was seen; the inactivity watchdog stays suspended from then on.
    public private(set) var isPostProcessing = false

    private static let progressPrefix = "SUNSHINE|"
    private static let filePrefix = "SUNSHINE_FILE|"
    private static let downloadPrefix = "[download] "
    private static let alreadyDownloadedSuffixes = [" has already been downloaded and merged", " has already been downloaded"]
    private static let errorPrefix = "ERROR: "

    public init() {}

    /// Returns the event for `line`, or nil for unrelated lines. A second completion with
    /// the same path (the "already downloaded" line followed by `SUNSHINE_FILE|`) yields nil.
    public mutating func consume(line rawLine: String) -> YTDLPEvent? {
        let line = rawLine.trimmingCharacters(in: .newlines)

        if line.hasPrefix(Self.filePrefix) {
            return complete(String(line.dropFirst(Self.filePrefix.count)))
        }
        if line.hasPrefix(Self.progressPrefix) {
            return Self.parseProgress(String(line.dropFirst(Self.progressPrefix.count)))
        }
        if line.hasPrefix("[Merger]") || line.hasPrefix("[Fixup") {
            isPostProcessing = true
            return .merging
        }
        if line.hasPrefix(Self.downloadPrefix) {
            let body = String(line.dropFirst(Self.downloadPrefix.count))
            for suffix in Self.alreadyDownloadedSuffixes where body.hasSuffix(suffix) {
                return complete(String(body.dropLast(suffix.count)))
            }
            if body.contains("does not pass filter"), body.contains("is_live") {
                return .error(.liveStream, message: body)
            }
            return nil
        }
        if line.hasPrefix(Self.errorPrefix) {
            let message = String(line.dropFirst(Self.errorPrefix.count))
            return .error(Self.classify(message), message: message)
        }
        return nil
    }

    private mutating func complete(_ path: String) -> YTDLPEvent? {
        guard !path.isEmpty, path != "NA" else { return nil }
        defer { completedPath = path }
        return completedPath == path ? nil : .completed(path: path)
    }

    /// `<status>|<downloaded>|<total>|<estimate>|<vcodec>`
    private static func parseProgress(_ body: String) -> YTDLPEvent? {
        let fields = body.split(separator: "|", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 5 else { return nil }
        let (status, downloaded, total, estimate, vcodec) = (fields[0], fields[1], fields[2], fields[3], fields[4])

        let phase: DownloadPhase = switch vcodec {
        case "none": .audio
        case "", "NA": .unknown
        default: .video
        }
        var fraction: Double?
        if let done = number(downloaded), let whole = number(total) ?? number(estimate), whole > 0 {
            fraction = min(max(done / whole, 0), 1)
        }
        if fraction == nil, status == "finished" { fraction = 1 }
        return .progress(phase: phase, fraction: fraction)
    }

    /// yt-dlp prints `NA` for missing fields; estimates may be floats.
    private static func number(_ s: String) -> Double? {
        guard let v = Double(s), v.isFinite else { return nil }
        return v
    }

    private static let liveMarkers = ["live stream", "live event", "is live", "premieres in"]
    private static let unavailableMarkers = [
        "video unavailable", "is unavailable", "private video", "has been removed", "been terminated",
        "does not exist", "not available", "incomplete youtube id", "copyright claim",
    ]
    private static let networkMarkers = [
        "unable to download", "unable to connect", "connection refused", "connection reset", "timed out",
        "network is unreachable", "nodename nor servname", "name or service not known", "failed to resolve",
        "temporary failure in name resolution", "getaddrinfo", "urlopen error", "proxyerror", "transporterror",
        "ssl:",
        // macOS errnos: ENETDOWN, ENETUNREACH, ECONNRESET, ETIMEDOUT, ECONNREFUSED, EHOSTDOWN,
        // EHOSTUNREACH, plus getaddrinfo's EAI_NONAME (8).
        "[errno 8]", "[errno 50]", "[errno 51]", "[errno 54]", "[errno 60]", "[errno 61]", "[errno 64]", "[errno 65]",
    ]
    /// Local file-system failures; they carry an `[Errno N]` too but aren't network errors.
    private static let localFileMarkers = ["permission denied", "operation not permitted", "no space left", "read-only file system"]
    private static let outdatedMarkers = [
        "unable to extract", "please report this issue", "yt-dlp -u", "signature extraction failed",
        "nsig extraction failed", "challenge", "unsupported url",
    ]

    /// Order matters: network failures also carry yt-dlp's "please report this issue …
    /// yt-dlp -U" boilerplate, and "live stream recording is not available" is a live-stream case.
    static func classify(_ message: String) -> DownloadErrorKind {
        let m = message.lowercased()
        // No mp4/avc1 ≤ 1080p format; not an availability problem.
        if m.contains("requested format is not available") { return .generic }
        if localFileMarkers.contains(where: m.contains) { return .generic }
        if liveMarkers.contains(where: m.contains) { return .liveStream }
        if networkMarkers.contains(where: m.contains) { return .network }
        if unavailableMarkers.contains(where: m.contains) { return .unavailable }
        if outdatedMarkers.contains(where: m.contains) { return .outdated }
        return .generic
    }
}
