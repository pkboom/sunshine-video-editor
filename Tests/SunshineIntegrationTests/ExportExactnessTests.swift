import AVFoundation
import SunshineCore
import XCTest

/// AC 9/10/11: passthrough exports decode to exactly the selected number of frames.
@MainActor
final class ExportExactnessTests: XCTestCase {
    /// One AAC frame at 48 kHz.
    private let aacFrame = 1024.0 / 48000.0

    func testKeepSnappedTwoRangesIs600FramesAnd20Seconds() async throws {
        let src = try await LoadedSource.open(try FixtureFactory.copy(.gop2bf2, in: self))
        let plan = try src.plan([(10, 20), (30, 40)], mode: .keep, snap: .keyframe)
        XCTAssertTimeEqual(plan.totalDuration, CMTime(value: 20, timescale: 1))

        let out = try await runExport(try await src.composition(plan), source: src.url)
        XCTAssertEqual(try Probe.frameCount(out.url), 600)
        let ranges = try await Probe.trackRanges(out.url)
        XCTAssertTimeEqual(ranges.video.duration, CMTime(value: 20, timescale: 1))
        let audio = try XCTUnwrap(ranges.audio)
        XCTAssertEqual(audio.duration.seconds, 20.0, accuracy: aacFrame)
    }

    func testRemoveSnappedTwoRangesIs1200Frames() async throws {
        let src = try await LoadedSource.open(try FixtureFactory.copy(.gop2bf2, in: self))
        let plan = try src.plan([(10, 20), (30, 40)], mode: .remove, snap: .keyframe)
        XCTAssertEqual(plan.segments.count, 3)

        let out = try await runExport(try await src.composition(plan), source: src.url)
        XCTAssertEqual(try Probe.frameCount(out.url), 1200)
        let ranges = try await Probe.trackRanges(out.url)
        XCTAssertTimeEqual(ranges.video.duration, CMTime(value: 40, timescale: 1))
    }

    func testOffKeyframeFrameExactKeepIs525Frames() async throws {
        let src = try await LoadedSource.open(try FixtureFactory.copy(.gop2bf2, in: self))
        let plan = try src.plan([(10.5, 28.0)], mode: .keep, snap: .frame)
        XCTAssertTimeEqual(plan.segments[0].start, src.time(10.5))
        XCTAssertTimeEqual(plan.segments[0].end, src.time(28.0))

        let out = try await runExport(try await src.composition(plan), source: src.url)
        XCTAssertEqual(try Probe.frameCount(out.url), 525)
    }

    func testOffKeyframeFrameExactTwoRangesIs258Frames() async throws {
        let src = try await LoadedSource.open(try FixtureFactory.copy(.gop2bf2, in: self))
        let plan = try src.plan([(3.5, 7.2), (20.1, 25.0)], mode: .keep, snap: .frame)

        let out = try await runExport(try await src.composition(plan), source: src.url)
        XCTAssertEqual(try Probe.frameCount(out.url), 111 + 147)
    }

    /// Keep [10,20]: the output's first frame is the source frame at 10.000 s.
    func testFirstFrameMatchesSourceFrame() async throws {
        let src = try await LoadedSource.open(try FixtureFactory.copy(.gop2bf2, in: self))
        let plan = try src.plan([(10, 20)], mode: .keep, snap: .keyframe)

        let out = try await runExport(try await src.composition(plan), source: src.url)
        let psnr = try Probe.firstFramePSNR(out.url, against: src.url, atSeconds: 10.0)
        XCTAssertGreaterThanOrEqual(psnr, 40, "PSNR \(psnr) dB")
    }
}
