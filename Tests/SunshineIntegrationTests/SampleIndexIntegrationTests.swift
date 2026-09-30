import AVFoundation
import SunshineCore
import XCTest

@MainActor
final class SampleIndexIntegrationTests: XCTestCase {
    /// C1 (sample cursor mapped through the edit list): keyframes land exactly on the 2 s grid in track
    /// time, although the pre-edit-list media time of the first keyframe is 2 frames later (-bf 2).
    func testCursorIndexSyncGridIsExact() async throws {
        let src = try await LoadedSource.open(try FixtureFactory.url(.gop2bf2))
        let ts = try await src.video.load(.naturalTimeScale)
        XCTAssertEqual(src.index.timescale, ts)

        let expected = (0..<30).map { CMTime(value: CMTimeValue($0) * 2 * CMTimeValue(ts), timescale: ts) }
        XCTAssertEqual(src.index.syncPTS.count, expected.count)
        for (got, want) in zip(src.index.syncPTS, expected) { XCTAssertTimeEqual(got, want) }

        XCTAssertEqual(src.index.allPTS.count, 1800)
        for (a, b) in zip(src.index.allPTS, src.index.allPTS.dropFirst()) {
            XCTAssertLessThan(CMTimeCompare(a, b), 0, "allPTS must be strictly increasing (sorted, no duplicates)")
        }
        XCTAssertTimeEqual(src.index.allPTS[0], .zero)
        XCTAssertTimeEqual(src.index.allPTS[1799], CMTime(value: 1799 * CMTimeValue(ts) / 30, timescale: ts))

        let domain = try await src.video.load(.timeRange)
        XCTAssertTimeEqual(src.index.domain.start, domain.start)
        XCTAssertTimeEqual(src.index.domain.end, domain.end)
        XCTAssertTimeEqual(src.index.domain.duration, CMTime(value: 60, timescale: 1))
    }

    /// C2 (AVAssetReader passthrough) forced on the same file yields the identical index.
    func testForcedReaderMatchesCursor() async throws {
        let url = try FixtureFactory.url(.gop2bf2)
        let c1 = try await LoadedSource.open(url).index
        let c2 = try await LoadedSource.open(url, forceReader: true).index

        XCTAssertEqual(c2.timescale, c1.timescale)
        XCTAssertEqual(c2.syncPTS.count, c1.syncPTS.count)
        for (a, b) in zip(c2.syncPTS, c1.syncPTS) { XCTAssertTimeEqual(a, b) }
        XCTAssertEqual(c2.allPTS.count, c1.allPTS.count)
        for (a, b) in zip(c2.allPTS, c1.allPTS) { XCTAssertTimeEqual(a, b) }
        XCTAssertTimeEqual(c2.domain.start, c1.domain.start)
        XCTAssertTimeEqual(c2.domain.duration, c1.domain.duration)
    }
}
