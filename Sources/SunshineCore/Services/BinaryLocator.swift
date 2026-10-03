import Darwin
import Foundation

public enum Helper: String, Sendable, CaseIterable {
    case ytdlp = "yt-dlp"
    case deno
    case ffmpeg
}

public enum BinaryLocatorError: Error, Equatable, Sendable, LocalizedError {
    /// No executable helper in the override dir, the app bundle or (unbundled) `$SUNSHINE_HELPERS_DIR`.
    case notFound(Helper)
    /// macOS refused to run the helper (quarantine / Gatekeeper). `appPath` goes into the xattr hint.
    case blocked(Helper, appPath: String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let helper):
            "Helper '\(helper.rawValue)' is missing from Sunshine. Download Sunshine again."
        case .blocked(let helper, let appPath):
            "Helper '\(helper.rawValue)' was blocked by macOS. Run: xattr -dr com.apple.quarantine '\(appPath.replacingOccurrences(of: "'", with: "'\\''"))'"
        }
    }
}

/// Finds bundled helper binaries. Order:
/// 1. `~/Library/Application Support/Sunshine/bin/<name>` (lets friends drop in a newer yt-dlp)
/// 2. `<app>/Contents/Helpers/<name>`
/// 3. `$SUNSHINE_HELPERS_DIR/<name>`, only when not running from a .app (`swift run`, tests)
///
/// `PATH` is never searched, and quarantine attributes are never touched at runtime.
public enum BinaryLocator {
    public static var overrideDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sunshine/bin", isDirectory: true)
    }

    public static func url(for helper: Helper) throws -> URL {
        try url(for: helper,
                overrideDirectory: overrideDirectory,
                bundleURL: Bundle.main.bundleURL,
                environment: ProcessInfo.processInfo.environment)
    }

    static func url(for helper: Helper, overrideDirectory: URL?, bundleURL: URL, environment: [String: String]) throws -> URL {
        var candidates: [URL] = []
        if let overrideDirectory { candidates.append(overrideDirectory) }
        if isAppBundle(bundleURL) {
            candidates.append(bundleURL.appendingPathComponent("Contents/Helpers", isDirectory: true))
        } else if let dev = environment["SUNSHINE_HELPERS_DIR"], !dev.isEmpty {
            candidates.append(URL(fileURLWithPath: dev, isDirectory: true))
        }
        for dir in candidates {
            let file = dir.appendingPathComponent(helper.rawValue)
            if isExecutableFile(file) { return file }
        }
        throw BinaryLocatorError.notFound(helper)
    }

    /// Maps a launch failure of `helper` to `.blocked` when macOS refused to run it:
    /// spawn failing with EACCES/EPERM, or SIGKILL before the helper printed anything
    /// (how Gatekeeper/AMFI rejects a quarantined or badly signed binary). Other errors pass through.
    public static func classifyLaunchFailure(_ error: Error, helper: Helper, producedOutput: Bool) -> Error {
        let blocked: Bool = switch error as? ProcessRunnerError {
        case .spawnFailed(_, let code): code == EACCES || code == EPERM
        case .terminatedBySignal(let sig): sig == SIGKILL && !producedOutput
        default: false
        }
        return blocked ? BinaryLocatorError.blocked(helper, appPath: blockedHintPath) : error
    }

    private static var blockedHintPath: String {
        isAppBundle(Bundle.main.bundleURL) ? Bundle.main.bundleURL.path : "/Applications/Sunshine.app"
    }

    static func isAppBundle(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "app"
    }

    private static func isExecutableFile(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && !isDir.boolValue
            && FileManager.default.isExecutableFile(atPath: url.path)
    }
}
