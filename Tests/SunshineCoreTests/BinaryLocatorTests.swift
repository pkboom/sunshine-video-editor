import Darwin
import Foundation
import Testing
@testable import SunshineCore

/// A scratch directory tree, removed on deinit.
final class TempDir {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("sunshine-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }

    func dir(_ path: String) throws -> URL {
        let d = url.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @discardableResult
    func file(_ path: String, _ contents: String = "", mode: Int = 0o644) throws -> URL {
        let f = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: f, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: f.path)
        return f
    }
}

@Suite struct BinaryLocatorTests {
    @Test func bundledHelperIsFoundInsideApp() throws {
        let t = try TempDir()
        let app = try t.dir("Sunshine.app")
        let helper = try t.file("Sunshine.app/Contents/Helpers/yt-dlp", mode: 0o755)
        let found = try BinaryLocator.url(for: .ytdlp, overrideDirectory: t.url.appendingPathComponent("none"),
                                          bundleURL: app, environment: [:])
        #expect(found == helper)
    }

    @Test func overrideDirectoryWinsOverBundle() throws {
        let t = try TempDir()
        let app = try t.dir("Sunshine.app")
        try t.file("Sunshine.app/Contents/Helpers/yt-dlp", mode: 0o755)
        let override = try t.file("override/yt-dlp", mode: 0o755)
        let found = try BinaryLocator.url(for: .ytdlp, overrideDirectory: override.deletingLastPathComponent(),
                                          bundleURL: app, environment: [:])
        #expect(found == override)
    }

    @Test func nonExecutableOverrideFallsThroughToBundle() throws {
        let t = try TempDir()
        let app = try t.dir("Sunshine.app")
        let bundled = try t.file("Sunshine.app/Contents/Helpers/deno", mode: 0o755)
        let override = try t.file("override/deno", mode: 0o644)
        let found = try BinaryLocator.url(for: .deno, overrideDirectory: override.deletingLastPathComponent(),
                                          bundleURL: app, environment: [:])
        #expect(found == bundled)
    }

    @Test func devDirectoryIsUsedOnlyWhenUnbundled() throws {
        let t = try TempDir()
        let dev = try t.file("dev/ffmpeg", mode: 0o755)
        let env = ["SUNSHINE_HELPERS_DIR": dev.deletingLastPathComponent().path]

        let unbundled = try t.dir("debug")
        #expect(try BinaryLocator.url(for: .ffmpeg, overrideDirectory: nil, bundleURL: unbundled, environment: env) == dev)

        let app = try t.dir("Sunshine.app")
        #expect(throws: BinaryLocatorError.notFound(.ffmpeg)) {
            try BinaryLocator.url(for: .ffmpeg, overrideDirectory: nil, bundleURL: app, environment: env)
        }
    }

    @Test func pathIsNeverSearched() throws {
        let t = try TempDir()
        let onPath = try t.file("bin/ffmpeg", mode: 0o755)
        let env = ["PATH": onPath.deletingLastPathComponent().path + ":/opt/homebrew/bin:/usr/bin:/bin"]
        #expect(throws: BinaryLocatorError.notFound(.ffmpeg)) {
            try BinaryLocator.url(for: .ffmpeg, overrideDirectory: nil, bundleURL: try t.dir("debug"), environment: env)
        }
    }

    @Test func directoryWithHelperNameIsIgnored() throws {
        let t = try TempDir()
        let app = try t.dir("Sunshine.app")
        _ = try t.dir("Sunshine.app/Contents/Helpers/yt-dlp")
        #expect(throws: BinaryLocatorError.notFound(.ytdlp)) {
            try BinaryLocator.url(for: .ytdlp, overrideDirectory: nil, bundleURL: app, environment: [:])
        }
    }

    @Test func helperFileNames() {
        #expect(Helper.allCases.map(\.rawValue) == ["yt-dlp", "deno", "ffmpeg"])
    }

    @Test func blockedErrorCarriesXattrHint() {
        let e = BinaryLocatorError.blocked(.ytdlp, appPath: "/Applications/Sunshine.app")
        #expect(e.localizedDescription
            == "Helper 'yt-dlp' was blocked by macOS. Run: xattr -dr com.apple.quarantine '/Applications/Sunshine.app'")
    }

    @Test func blockedHintQuotesThePath() {
        let e = BinaryLocatorError.blocked(.ytdlp, appPath: "/Users/me/Downloads/Sunshine 2 (Bo's).app")
        #expect(e.localizedDescription
            == #"Helper 'yt-dlp' was blocked by macOS. Run: xattr -dr com.apple.quarantine '/Users/me/Downloads/Sunshine 2 (Bo'\''s).app'"#)
    }

    @Test func launchFailuresMapToBlocked() {
        func mapped(_ e: Error, output: Bool = false) -> BinaryLocatorError? {
            BinaryLocator.classifyLaunchFailure(e, helper: .deno, producedOutput: output) as? BinaryLocatorError
        }
        #expect(mapped(ProcessRunnerError.spawnFailed(executable: "x", errno: EACCES)) != nil)
        #expect(mapped(ProcessRunnerError.spawnFailed(executable: "x", errno: EPERM)) != nil)
        #expect(mapped(ProcessRunnerError.terminatedBySignal(SIGKILL)) != nil)
        // Not a launch refusal:
        #expect(mapped(ProcessRunnerError.spawnFailed(executable: "x", errno: ENOENT)) == nil)
        #expect(mapped(ProcessRunnerError.terminatedBySignal(SIGKILL), output: true) == nil)
        #expect(mapped(ProcessRunnerError.terminatedBySignal(SIGSEGV)) == nil)
        #expect(mapped(CancellationError()) == nil)
    }
}

extension ProcessSpawningTests {
    @Suite struct BinaryLocatorLaunchTests {
        @Test func blockedExecutableIsReportedWithHint() async throws {
            let t = try TempDir()
            let notExecutable = try t.file("yt-dlp", "#!/bin/sh\necho hi\n", mode: 0o644)
            do {
                _ = try await ProcessRunner().run(executable: notExecutable, args: [])
                Issue.record("spawning a non-executable file succeeded")
            } catch {
                let mapped = BinaryLocator.classifyLaunchFailure(error, helper: .ytdlp, producedOutput: false)
                #expect(mapped.localizedDescription.contains("xattr -dr com.apple.quarantine"))
            }
        }
    }
}
