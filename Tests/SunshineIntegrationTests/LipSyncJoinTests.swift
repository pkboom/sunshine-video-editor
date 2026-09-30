import AVFoundation
import SunshineCore
import XCTest

/// AC 11: audio and video stay in sync at every join. The flashbeep fixture has one white frame and one
/// 20 ms beep at each integer second, so every flash must have a beep onset within one frame.
@MainActor
final class LipSyncJoinTests: XCTestCase {
    static let frame = 1.0 / 30.0
    static let tolerance = 0.0334

    func testSnappedJoinsStayInSync() async throws {
        let src = try await LoadedSource.open(try FixtureFactory.copy(.flashbeep, in: self))
        let plan = try src.plan([(2, 4), (6, 8), (12, 14)], mode: .keep, snap: .keyframe)
        let out = try await runExport(try await src.composition(plan), source: src.url)
        XCTAssertEqual(try Probe.frameCount(out.url), 180)
        try Self.assertInSync(out.url, joins: joinTimes(plan))
    }

    func testFrameExactJoinsStayInSync() async throws {
        let src = try await LoadedSource.open(try FixtureFactory.copy(.flashbeep, in: self))
        let plan = try src.plan([(1.5, 4.3), (7.1, 9.8), (12.4, 15.0)], mode: .keep, snap: .frame)
        let out = try await runExport(try await src.composition(plan), source: src.url)
        XCTAssertEqual(try Probe.frameCount(out.url), 84 + 81 + 78)
        try Self.assertInSync(out.url, joins: joinTimes(plan))
    }

    /// For every flash within ±2 s of a join, the nearest beep onset is within one frame. Flashes in the
    /// first 0.5 s are excluded: a beep at t = 0 has no preceding silence for `silencedetect` to end.
    static func assertInSync(_ url: URL, joins: [Double], file: StaticString = #filePath, line: UInt = #line) throws {
        let flashes = try Probe.flashTimes(url)
        let beeps = try Probe.beepOnsets(url)
        XCTAssertFalse(joins.isEmpty, file: file, line: line)
        for join in joins {
            let near = flashes.filter { abs($0 - join) <= 2 && $0 >= 0.5 }
            XCTAssertGreaterThanOrEqual(near.count, 2, "flashes near join \(join): \(near)", file: file, line: line)
            var worst = 0.0
            for flash in near {
                let offset = beeps.map { $0 - flash }.min { abs($0) < abs($1) } ?? .infinity
                worst = max(worst, abs(offset))
                XCTAssertLessThanOrEqual(abs(offset), tolerance,
                                         "join \(join)s: flash \(flash)s has beep offset \(offset * 1000) ms",
                                         file: file, line: line)
            }
            print("[LipSync] \(url.lastPathComponent) join \(join)s: \(near.count) flashes, worst offset \(worst * 1000) ms")
        }
    }
}
