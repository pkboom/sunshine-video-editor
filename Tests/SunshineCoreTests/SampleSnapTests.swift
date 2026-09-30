import CoreMedia
import Testing
@testable import SunshineCore

// MARK: - Shared test helpers (used by the Model test suites)

/// Exact time: `value / ts` seconds.
func T(_ value: Int64, _ ts: CMTimeScale) -> CMTime { CMTime(value: value, timescale: ts) }

/// Seconds (must be representable in `ts`) → exact CMTime.
func S(_ seconds: Double, _ ts: CMTimeScale) -> CMTime {
    CMTime(value: Int64((seconds * Double(ts)).rounded()), timescale: ts)
}

func R(_ start: CMTime, _ end: CMTime) -> CMTimeRange { CMTimeRange(start: start, end: end) }

func R(_ start: Double, _ end: Double, _ ts: CMTimeScale) -> CMTimeRange { R(S(start, ts), S(end, ts)) }

/// Exact equality of two ranges' start and end.
func same(_ a: CMTimeRange, _ b: CMTimeRange) -> Bool {
    CMTimeCompare(a.start, b.start) == 0 && CMTimeCompare(a.end, b.end) == 0
}

/// `count` frames of `frameDuration` starting at `domainStart`, sync every `gop` frames.
func makeIndex(ts: CMTimeScale, frameDuration: Int64, count: Int, gop: Int, domainStart: Int64 = 0) -> SampleIndex {
    let all = (0..<count).map { T(domainStart + Int64($0) * frameDuration, ts) }
    let sync = stride(from: 0, to: count, by: gop).map { all[$0] }
    let domain = R(T(domainStart, ts), T(domainStart + Int64(count) * frameDuration, ts))
    return SampleIndex(timescale: ts, allPTS: all, syncPTS: sync, domain: domain)
}

/// 30 fps, keyframes at [0, 2, 4, 6, 8] s, D = [0, 9) s, ts = 600.
let gop2Index = makeIndex(ts: 600, frameDuration: 20, count: 270, gop: 60)

@Suite struct SampleSnapTests {
    let ts: CMTimeScale = 600

    @Test func keyframeSnapsToNearestSync() throws {
        let r = try gop2Index.snap(R(3.3, 7.7, ts), mode: .keyframe)
        #expect(same(r, R(4, 8, ts)))
    }

    @Test func keyframeStartTieGoesEarlier() throws {
        let r = try gop2Index.snap(R(3, 7.9, ts), mode: .keyframe)
        #expect(same(r, R(2, 8, ts)))
    }

    @Test func keyframeEndTieGoesEarlier() throws {
        let r = try gop2Index.snap(R(1.9, 5, ts), mode: .keyframe)
        #expect(same(r, R(2, 4, ts)))
    }

    @Test func collapsedEndGoesToNextSync() throws {
        // Both edges are nearest to 4 s; the end must land strictly after the start.
        let r = try gop2Index.snap(R(3.3, 3.4, ts), mode: .keyframe)
        #expect(same(r, R(4, 6, ts)))
    }

    @Test func endNearDomainEndGoesToDomainEnd() throws {
        let r = try gop2Index.snap(R(6.2, 8.8, ts), mode: .keyframe)
        #expect(same(r, R(6, 9, ts)))
    }

    @Test func endWithNoLaterSyncGoesToDomainEnd() throws {
        let r = try gop2Index.snap(R(8.1, 8.2, ts), mode: .keyframe)
        #expect(same(r, R(8, 9, ts)))
    }

    @Test func frameModeSnapsToExactSamplePTSAt2997() throws {
        // 29.97 fps: PTS k * 1001 / 30000.
        let index = makeIndex(ts: 30000, frameDuration: 1001, count: 300, gop: 60)
        let r = try index.snap(R(3.3, 7.7, 30000), mode: .frame)
        // 3.3 s = 99000 → frame 98.9 → 99; 7.7 s = 231000 → frame 230.77 → 231.
        #expect(same(r, R(T(99 * 1001, 30000), T(231 * 1001, 30000))))
        #expect(r.start.timescale == 30000 && r.end.timescale == 30000)
    }

    @Test func frameModeCollapsedEndGoesToNextFrame() throws {
        let index = makeIndex(ts: 30000, frameDuration: 1001, count: 300, gop: 60)
        let r = try index.snap(R(T(99 * 1001, 30000), T(99 * 1001 + 10, 30000)), mode: .frame)
        #expect(same(r, R(T(99 * 1001, 30000), T(100 * 1001, 30000))))
    }

    @Test func snapUsesDomainWithNonZeroStart() throws {
        // D = [10, 19) s, keyframes at 10, 12, …, 18.
        let index = makeIndex(ts: 600, frameDuration: 20, count: 270, gop: 60, domainStart: 6000)
        let r = try index.snap(R(0, 100, ts), mode: .keyframe)
        #expect(same(r, R(10, 19, ts)))
        let inner = try index.snap(R(13.3, 17.7, ts), mode: .keyframe)
        #expect(same(inner, R(14, 18, ts)))
    }

    @Test func negativeDurationInputIsNormalized() throws {
        let reversed = CMTimeRange(start: S(7.7, ts), duration: S(-4.4, ts))
        let r = try gop2Index.snap(reversed, mode: .keyframe)
        #expect(same(r, R(4, 8, ts)))
    }

    @Test func emptyIndexThrows() {
        let empty = SampleIndex(timescale: ts, allPTS: [], syncPTS: [], domain: R(0, 9, ts))
        #expect(throws: SnapError.emptyIndex) { try empty.snap(R(1, 2, ts), mode: .keyframe) }
        #expect(throws: SnapError.emptyIndex) { try empty.snap(R(1, 2, ts), mode: .frame) }
    }

    @Test func keyframeModeWithoutSyncSamplesThrows() {
        let noSync = SampleIndex(timescale: ts, allPTS: gop2Index.allPTS, syncPTS: [], domain: gop2Index.domain)
        #expect(throws: SnapError.emptyIndex) { try noSync.snap(R(1, 2, ts), mode: .keyframe) }
        #expect(throws: Never.self) { try noSync.snap(R(1, 2, ts), mode: .frame) }
    }

    @Test func toggleResnapsFromRawTimes() throws {
        var set = RangeSet(domain: gop2Index.domain)
        let id = try set.insert(raw: R(3.3, 7.7, ts), index: gop2Index, mode: .keyframe)
        #expect(same(set.ranges[0].snapped, R(4, 8, ts)))
        try set.resnap(index: gop2Index, mode: .frame)
        #expect(set.ranges[0].id == id)
        #expect(same(set.ranges[0].snapped, R(3.3, 7.7, ts)))
        try set.resnap(index: gop2Index, mode: .keyframe)
        #expect(same(set.ranges[0].snapped, R(4, 8, ts)))
        #expect(same(set.ranges[0].raw, R(3.3, 7.7, ts)))
    }
}
