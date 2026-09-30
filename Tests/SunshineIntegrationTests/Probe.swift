import AVFoundation
import CryptoKit
import Foundation

enum ProbeError: Error, CustomStringConvertible {
    case toolMissing(String)
    case failed(tool: String, status: Int32, stderr: String)
    case unparsable(String)

    var description: String {
        switch self {
        case .toolMissing(let path):
            "Required test tool not found at \(path). Install Homebrew ffmpeg (brew install ffmpeg) or set SUNSHINE_FIXTURE_FFMPEG / SUNSHINE_FIXTURE_FFPROBE."
        case .failed(let tool, let status, let stderr):
            "\(tool) exited \(status): \(stderr.suffix(2000))"
        case .unparsable(let what):
            "Couldn't parse \(what)"
        }
    }
}

/// Dev-side measurements with Homebrew ffmpeg/ffprobe (tests only) plus AVFoundation track timing.
enum Probe {
    /// Runs a tool and returns (stdout, stderr). Throws on a missing tool or a non-zero exit.
    @discardableResult
    static func run(_ tool: URL, _ args: [String]) throws -> (out: String, err: String) {
        guard FileManager.default.isExecutableFile(atPath: tool.path) else { throw ProbeError.toolMissing(tool.path) }
        // stderr goes to a file so a chatty tool can never block on a full pipe while stdout is read.
        let errURL = FileManager.default.temporaryDirectory.appendingPathComponent("sunshine-probe-\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: errURL) }
        let errHandle = try FileHandle(forWritingTo: errURL)
        defer { try? errHandle.close() }
        let p = Process()
        p.executableURL = tool
        p.arguments = args
        let outPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errHandle
        p.standardInput = FileHandle.nullDevice
        try p.run()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let errData = (try? Data(contentsOf: errURL)) ?? Data()
        let out = String(decoding: outData, as: UTF8.self)
        let err = String(decoding: errData, as: UTF8.self)
        guard p.terminationStatus == 0 else {
            throw ProbeError.failed(tool: tool.lastPathComponent, status: p.terminationStatus, stderr: err)
        }
        return (out, err)
    }

    /// Decoded video frame count (`ffprobe -count_frames`, honours edit lists).
    static func frameCount(_ url: URL) throws -> Int {
        let r = try run(FixtureFactory.ffprobe, ["-v", "error", "-count_frames", "-select_streams", "v:0",
                                                 "-show_entries", "stream=nb_read_frames", "-of", "csv=p=0", url.path])
        guard let n = Int(r.out.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw ProbeError.unparsable("nb_read_frames: \(r.out)")
        }
        return n
    }

    /// Presentation times (s) of decoded frames whose average luma is above 200.
    static func flashTimes(_ url: URL) throws -> [Double] {
        let r = try run(FixtureFactory.ffmpeg, ["-v", "error", "-i", url.path, "-an", "-vf",
                                                "signalstats,metadata=print:key=lavfi.signalstats.YAVG:file=-",
                                                "-f", "null", "-"])
        var times: [Double] = []
        var pending: Double?
        for line in r.out.split(separator: "\n") {
            if let range = line.range(of: "pts_time:") {
                pending = Double(line[range.upperBound...].trimmingCharacters(in: .whitespaces))
            } else if let range = line.range(of: "YAVG="), let t = pending,
                      let y = Double(line[range.upperBound...]), y > 200 {
                times.append(t)
            }
        }
        return times
    }

    /// Beep onsets (s): the ends of silences detected by `silencedetect`.
    static func beepOnsets(_ url: URL) throws -> [Double] {
        let r = try run(FixtureFactory.ffmpeg, ["-v", "info", "-nostats", "-i", url.path, "-vn",
                                                "-af", "silencedetect=n=-40dB:d=0.1", "-f", "null", "-"])
        return r.err.split(separator: "\n").compactMap { line in
            guard let range = line.range(of: "silence_end: ") else { return nil }
            return Double(line[range.upperBound...].prefix { !$0.isWhitespace })
        }
    }

    /// PSNR (dB) between `a`'s first frame and `b`'s frame at `bSeconds`. Identical frames give `.infinity`.
    static func firstFramePSNR(_ a: URL, against b: URL, atSeconds bSeconds: Double) throws -> Double {
        let graph = "[0:v]trim=end_frame=1,setpts=PTS-STARTPTS[a];"
            + "[1:v]trim=start=\(bSeconds),setpts=PTS-STARTPTS,trim=end_frame=1[b];[a][b]psnr"
        let r = try run(FixtureFactory.ffmpeg, ["-v", "info", "-nostats", "-i", a.path, "-i", b.path,
                                                "-filter_complex", graph, "-f", "null", "-"])
        guard let line = r.err.split(separator: "\n").last(where: { $0.contains("PSNR") }),
              let range = line.range(of: "average:") else {
            throw ProbeError.unparsable("psnr: \(r.err.suffix(500))")
        }
        let value = line[range.upperBound...].prefix { !$0.isWhitespace }
        if value == "inf" { return .infinity }
        guard let db = Double(value) else { throw ProbeError.unparsable("psnr value \(value)") }
        return db
    }

    static func sha256(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    /// First video / audio track time ranges of a file on disk, via AVFoundation.
    static func trackRanges(_ url: URL) async throws -> (video: CMTimeRange, audio: CMTimeRange?) {
        let asset = AVURLAsset(url: url)
        let video = try await asset.loadTracks(withMediaType: .video)[0].load(.timeRange)
        let audio = try await asset.loadTracks(withMediaType: .audio).first?.load(.timeRange)
        return (video, audio)
    }
}
