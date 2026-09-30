import AVFoundation
import SunshineCore
import XCTest

/// A source file opened the way the editor opens it: first video + first audio track and a sample index.
struct LoadedSource {
    let url: URL
    let asset: AVURLAsset
    let video: AVAssetTrack
    let audio: AVAssetTrack?
    let index: SampleIndex

    static func open(_ url: URL, forceReader: Bool = false) async throws -> LoadedSource {
        let asset = AVURLAsset(url: url)
        let video = try await asset.loadTracks(withMediaType: .video)[0]
        let audio = try await asset.loadTracks(withMediaType: .audio).first
        let index = try await SampleIndexLoader.load(asset: asset, videoTrack: video, forceReader: forceReader)
        return LoadedSource(url: url, asset: asset, video: video, audio: audio, index: index)
    }

    var ts: CMTimeScale { index.timescale }

    func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: ts) }

    /// Inserts raw ranges (seconds) with the given snap mode and builds the plan.
    func plan(_ ranges: [(Double, Double)], mode: ExportMode, snap: SnapMode) throws -> ExportPlan {
        var set = RangeSet(domain: index.domain)
        for (s, e) in ranges {
            _ = try set.insert(raw: CMTimeRange(start: time(s), end: time(e)), index: index, mode: snap)
        }
        return try ExportPlan(mode: mode, ranges: set)
    }

    @MainActor
    func composition(_ plan: ExportPlan) async throws -> AVComposition {
        try await CompositionBuilder.build(plan: plan, videoTrack: video, audioTrack: audio)
    }
}

struct ExportResult {
    let url: URL
    let progress: [Double]
}

@MainActor
func runExport(_ composition: AVComposition, source: URL, service: ExportService = ExportService()) async throws -> ExportResult {
    var progress: [Double] = []
    for try await update in service.export(composition, source: source) {
        switch update {
        case .progress(let p): progress.append(p)
        case .completed(let url): return ExportResult(url: url, progress: progress)
        }
    }
    throw ProbeError.unparsable("export stream ended without a completed URL")
}

/// Files in `dir` whose names match a predicate (hidden files included).
func files(in dir: URL, where match: (String) -> Bool) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: dir.path).filter(match).sorted()
}

func XCTAssertTimeEqual(_ a: CMTime, _ b: CMTime, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(CMTimeCompare(a, b), 0, "\(a.value)/\(a.timescale) (\(a.seconds)s) != \(b.value)/\(b.timescale) (\(b.seconds)s) \(message)",
                   file: file, line: line)
}

/// Output times of the joins between consecutive segments.
func joinTimes(_ plan: ExportPlan) -> [Double] {
    var t = CMTime.zero
    return plan.segments.dropLast().map { seg in
        t = t + seg.duration
        return t.seconds
    }
}
