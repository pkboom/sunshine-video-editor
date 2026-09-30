import Foundation
import Synchronization
import XCTest

/// Generates media fixtures with Homebrew ffmpeg (tests only) into `Generated/` and hands out
/// per-test copies in fresh temp directories, since exports are written next to the source.
enum FixtureFactory {
    enum Fixture: String, CaseIterable {
        /// testsrc2 1280x720@30, 60 s, GOP 2 s, 2 B-frames, 440 Hz sine AAC 48 kHz.
        case gop2bf2 = "gop2_bf2.mp4"
        /// Black 640x360@30 with one white frame per second, a 20 ms 1 kHz beep at each second. 20 s.
        case flashbeep = "flashbeep.mp4"
        /// Same as flashbeep, but the audio track ends 1 s before the video (19 s vs 20 s).
        case shortAudio = "flashbeep_short_audio.mp4"
        /// testsrc2 1920x1080@60 at a high bitrate, 60 s. Large enough that an export can be cancelled mid-way.
        case large = "large_1080p60.mp4"
    }

    static let generatedDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Generated", isDirectory: true)

    static var ffmpeg: URL { tool("SUNSHINE_FIXTURE_FFMPEG", default: "/opt/homebrew/bin/ffmpeg") }
    static var ffprobe: URL { tool("SUNSHINE_FIXTURE_FFPROBE", default: "/opt/homebrew/bin/ffprobe") }

    private static let lock = Mutex(())

    /// The generated fixture, created on first use.
    static func url(_ fixture: Fixture) throws -> URL {
        try lock.withLock { _ in
            let url = generatedDir.appendingPathComponent(fixture.rawValue)
            if FileManager.default.fileExists(atPath: url.path) { return url }
            try FileManager.default.createDirectory(at: generatedDir, withIntermediateDirectories: true)
            let tmp = generatedDir.appendingPathComponent(".tmp-\(UUID().uuidString)-\(fixture.rawValue)")
            defer { try? FileManager.default.removeItem(at: tmp) }
            try Probe.run(ffmpeg, ["-y", "-v", "error"] + arguments(fixture) + [tmp.path])
            try FileManager.default.moveItem(at: tmp, to: url)
            return url
        }
    }

    /// A copy of the fixture in a new temp directory (removed at test teardown).
    static func copy(_ fixture: Fixture, in testCase: XCTestCase) throws -> URL {
        let dir = try makeTempDir(in: testCase)
        let dst = dir.appendingPathComponent(fixture.rawValue)
        try FileManager.default.copyItem(at: try url(fixture), to: dst)
        return dst
    }

    static func makeTempDir(in testCase: XCTestCase) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sunshine-it-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        testCase.addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        return dir
    }

    private static func tool(_ env: String, default path: String) -> URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment[env] ?? path)
    }

    private static let x264 = ["-c:v", "libx264", "-preset", "veryfast", "-pix_fmt", "yuv420p",
                               "-g", "60", "-keyint_min", "60", "-sc_threshold", "0", "-bf", "2"]
    private static let aac = ["-c:a", "aac", "-b:a", "128k"]
    private static let flashVideo =
        "color=c=black:s=640x360:r=30:d=20,drawbox=x=0:y=0:w=iw:h=ih:color=white:t=fill:enable='eq(mod(n\\,30)\\,0)'"
    private static func beepAudio(seconds: Int) -> String {
        "aevalsrc='if(lt(mod(t\\,1)\\,0.02)\\,0.8*sin(2*PI*1000*t)\\,0)':s=48000:d=\(seconds)"
    }

    private static func arguments(_ fixture: Fixture) -> [String] {
        switch fixture {
        case .gop2bf2:
            return ["-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=30",
                    "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
                    "-t", "60", "-map", "0:v", "-map", "1:a"] + x264 + aac
        case .flashbeep:
            return ["-f", "lavfi", "-i", flashVideo, "-f", "lavfi", "-i", beepAudio(seconds: 20),
                    "-map", "0:v", "-map", "1:a"] + x264 + aac
        case .shortAudio:
            return ["-f", "lavfi", "-i", flashVideo, "-f", "lavfi", "-i", beepAudio(seconds: 19),
                    "-map", "0:v", "-map", "1:a"] + x264 + aac
        case .large:
            return ["-f", "lavfi", "-i", "testsrc2=size=1920x1080:rate=60",
                    "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
                    "-t", "60", "-map", "0:v", "-map", "1:a",
                    "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", "-qp", "8",
                    "-g", "120", "-keyint_min", "120", "-sc_threshold", "0", "-bf", "2"] + aac
        }
    }
}
