import CoreMedia
import Testing
@testable import SunshineCore

/// 30 fps-grid indexes in the three source timescales (frame duration in ts units), 10 s long.
let rangeSetTimescales: [(ts: CMTimeScale, frame: Int64)] = [(30000, 1000), (15360, 512), (600, 20)]

@Suite struct RangeSetTests {
    /// Frame mode on a 30 fps grid: whole-second ranges snap to themselves.
    func setUp(_ ts: CMTimeScale, _ frame: Int64) -> (RangeSet, SampleIndex) {
        let index = makeIndex(ts: ts, frameDuration: frame, count: 300, gop: 60)
        return (RangeSet(domain: index.domain), index)
    }

    func snappedRanges(_ set: RangeSet) -> [CMTimeRange] { set.ranges.map(\.snapped) }

    func expectRanges(_ set: RangeSet, _ expected: [CMTimeRange], sourceLocation: SourceLocation = #_sourceLocation) {
        let actual = snappedRanges(set)
        #expect(actual.count == expected.count, sourceLocation: sourceLocation)
        #expect(zip(actual, expected).allSatisfy(same), "\(actual) != \(expected)", sourceLocation: sourceLocation)
    }

    @Test(arguments: rangeSetTimescales)
    func disjointInsertKeepsOrder(_ p: (ts: CMTimeScale, frame: Int64)) throws {
        var (set, index) = setUp(p.ts, p.frame)
        try set.insert(raw: R(5, 6, p.ts), index: index, mode: .frame)
        try set.insert(raw: R(1, 2, p.ts), index: index, mode: .frame)
        try set.insert(raw: R(3, 4, p.ts), index: index, mode: .frame)
        expectRanges(set, [R(1, 2, p.ts), R(3, 4, p.ts), R(5, 6, p.ts)])
    }

    @Test(arguments: rangeSetTimescales)
    func overlapMerges(_ p: (ts: CMTimeScale, frame: Int64)) throws {
        var (set, index) = setUp(p.ts, p.frame)
        try set.insert(raw: R(1, 3, p.ts), index: index, mode: .frame)
        try set.insert(raw: R(2, 4, p.ts), index: index, mode: .frame)
        expectRanges(set, [R(1, 4, p.ts)])
    }

    @Test(arguments: rangeSetTimescales)
    func touchingMerges(_ p: (ts: CMTimeScale, frame: Int64)) throws {
        var (set, index) = setUp(p.ts, p.frame)
        try set.insert(raw: R(1, 2, p.ts), index: index, mode: .frame)
        try set.insert(raw: R(2, 3, p.ts), index: index, mode: .frame)
        expectRanges(set, [R(1, 3, p.ts)])
    }

    @Test(arguments: rangeSetTimescales)
    func containedIsAbsorbed(_ p: (ts: CMTimeScale, frame: Int64)) throws {
        var (set, index) = setUp(p.ts, p.frame)
        try set.insert(raw: R(1, 5, p.ts), index: index, mode: .frame)
        try set.insert(raw: R(2, 3, p.ts), index: index, mode: .frame)
        expectRanges(set, [R(1, 5, p.ts)])
        #expect(same(set.ranges[0].raw, R(1, 5, p.ts)))
    }

    @Test(arguments: rangeSetTimescales)
    func oneInsertSpanningThreeMergesToOne(_ p: (ts: CMTimeScale, frame: Int64)) throws {
        var (set, index) = setUp(p.ts, p.frame)
        try set.insert(raw: R(1, 2, p.ts), index: index, mode: .frame)
        try set.insert(raw: R(3, 4, p.ts), index: index, mode: .frame)
        try set.insert(raw: R(5, 6, p.ts), index: index, mode: .frame)
        let id = try set.insert(raw: R(1.5, 5.5, p.ts), index: index, mode: .frame)
        expectRanges(set, [R(1, 6, p.ts)])
        #expect(set.ranges[0].id == id)
    }

    @Test(arguments: rangeSetTimescales)
    func reversedIsNormalized(_ p: (ts: CMTimeScale, frame: Int64)) throws {
        var (set, index) = setUp(p.ts, p.frame)
        let id = try set.insert(from: S(4, p.ts), to: S(2, p.ts), index: index, mode: .frame)
        expectRanges(set, [R(2, 4, p.ts)])
        #expect(same(set.ranges[0].raw, R(2, 4, p.ts)))
        try set.update(id: id, from: S(6, p.ts), to: S(5, p.ts), index: index, mode: .frame)
        expectRanges(set, [R(5, 6, p.ts)])
    }

    @Test(arguments: rangeSetTimescales)
    func clampsToDomain(_ p: (ts: CMTimeScale, frame: Int64)) throws {
        var (set, index) = setUp(p.ts, p.frame)
        try set.insert(raw: R(-1, 20, p.ts), index: index, mode: .frame)
        expectRanges(set, [R(0, 10, p.ts)])
        #expect(same(set.ranges[0].raw, R(0, 10, p.ts)))
    }

    @Test(arguments: rangeSetTimescales)
    func clampsToDomainWithNonZeroStartAndEndBeforeAssetDuration(_ p: (ts: CMTimeScale, frame: Int64)) throws {
        // D = [2 s, 8.5 s): video track starts late and ends before the (longer) asset duration.
        let all = (0..<300).map { T(Int64($0) * p.frame, p.ts) }.filter {
            CMTimeCompare($0, S(2, p.ts)) >= 0 && CMTimeCompare($0, S(8.5, p.ts)) < 0
        }
        let domain = R(2, 8.5, p.ts)
        let index = SampleIndex(timescale: p.ts, allPTS: all, syncPTS: [all[0]], domain: domain)
        var set = RangeSet(domain: domain)
        try set.insert(raw: R(0, 10, p.ts), index: index, mode: .frame)
        expectRanges(set, [domain])
        #expect(same(set.ranges[0].raw, domain))
        #expect(set.complement().isEmpty)
    }

    @Test(arguments: rangeSetTimescales)
    func rangeOutsideDomainThrows(_ p: (ts: CMTimeScale, frame: Int64)) {
        var (set, index) = setUp(p.ts, p.frame)
        #expect(throws: RangeSetError.emptyRange) { try set.insert(raw: R(11, 12, p.ts), index: index, mode: .frame) }
        #expect(set.ranges.isEmpty)
    }

    @Test(arguments: rangeSetTimescales)
    func deleteByID(_ p: (ts: CMTimeScale, frame: Int64)) throws {
        var (set, index) = setUp(p.ts, p.frame)
        let a = try set.insert(raw: R(1, 2, p.ts), index: index, mode: .frame)
        let b = try set.insert(raw: R(3, 4, p.ts), index: index, mode: .frame)
        set.delete(id: a)
        #expect(set.ranges.map(\.id) == [b])
        expectRanges(set, [R(3, 4, p.ts)])
    }

    @Test(arguments: rangeSetTimescales)
    func updateMovesAndMergesKeepingID(_ p: (ts: CMTimeScale, frame: Int64)) throws {
        var (set, index) = setUp(p.ts, p.frame)
        try set.insert(raw: R(1, 2, p.ts), index: index, mode: .frame)
        let b = try set.insert(raw: R(5, 6, p.ts), index: index, mode: .frame)
        try set.update(id: b, raw: R(1.5, 7, p.ts), index: index, mode: .frame)
        expectRanges(set, [R(1, 7, p.ts)])
        #expect(set.ranges[0].id == b)
    }

    @Test func updateUnknownIDThrows() {
        var (set, index) = setUp(600, 20)
        #expect(throws: RangeSetError.unknownID) {
            try set.update(id: UUID(), raw: R(1, 2, 600), index: index, mode: .frame)
        }
    }

    @Test func mergedRawCoversMembersRawAndSnapped() throws {
        // Keyframes at 0, 2, 4, 6, 8 s. (3.3, 4.9) → (4, 6) and (6.2, 7.7) → (6, 8) touch on snapped times.
        var set = RangeSet(domain: gop2Index.domain)
        try set.insert(raw: R(3.3, 4.9, 600), index: gop2Index, mode: .keyframe)
        try set.insert(raw: R(6.2, 7.7, 600), index: gop2Index, mode: .keyframe)
        #expect(set.ranges.count == 1)
        // raw = union of raws (3.3, 7.7) widened by the snapped union (4, 8).
        #expect(same(set.ranges[0].raw, R(3.3, 8, 600)))
        #expect(same(set.ranges[0].snapped, R(4, 8, 600)))
    }

    /// Keyframes at 0, 5, 10, 15 s; D = [0, 20) s; 30 fps, ts 600.
    static let gop5Index = makeIndex(ts: 600, frameDuration: 20, count: 600, gop: 150)

    @Test func mergeNeverShrinksAMembersSnappedSpan() throws {
        // HIGH-1 regression: (5.0, 5.1) → (5, 10); (0, 4.9) → (0, 5) touches it. Re-snapping the raw
        // union (0, 5.1) alone gives (0, 5) and would silently drop (5, 10).
        let index = Self.gop5Index
        var set = RangeSet(domain: index.domain)
        try set.insert(raw: R(5, 5.1, 600), index: index, mode: .keyframe)
        #expect(same(set.ranges[0].snapped, R(5, 10, 600)))
        try set.insert(raw: R(0, 4.9, 600), index: index, mode: .keyframe)
        #expect(set.ranges.count == 1)
        #expect(same(set.ranges[0].snapped, R(0, 10, 600)))
        #expect(same(set.ranges[0].raw, R(0, 10, 600)))
    }

    @Test func resnapAfterMergeKeepsMergedSpan() throws {
        let index = Self.gop5Index
        var set = RangeSet(domain: index.domain)
        try set.insert(raw: R(5, 5.1, 600), index: index, mode: .keyframe)
        let id = try set.insert(raw: R(0, 4.9, 600), index: index, mode: .keyframe)
        for mode in [SnapMode.keyframe, .frame, .keyframe, .frame] {
            try set.resnap(index: index, mode: mode)
            #expect(set.ranges.count == 1, "\(mode)")
            #expect(set.ranges[0].id == id)
            #expect(same(set.ranges[0].snapped, R(0, 10, 600)), "\(mode)")
        }
    }

    @Test func mergeAcrossThreeKeepsEveryMembersSnappedSpan() throws {
        // Every member's snapped span must be inside the merged snapped span.
        let index = Self.gop5Index
        var set = RangeSet(domain: index.domain)
        try set.insert(raw: R(5, 5.1, 600), index: index, mode: .keyframe)     // (5, 10)
        try set.insert(raw: R(15, 15.1, 600), index: index, mode: .keyframe)   // (15, 20)
        let before = set.ranges.map(\.snapped)
        try set.insert(raw: R(9.9, 14.9, 600), index: index, mode: .keyframe)  // (10, 15) touches both
        #expect(set.ranges.count == 1)
        for s in before { #expect(CMTimeRangeContainsTimeRange(set.ranges[0].snapped, otherRange: s)) }
        #expect(same(set.ranges[0].snapped, R(5, 20, 600)))
    }

    @Test func coversWholeDomain() throws {
        var set = RangeSet(domain: gop2Index.domain)
        #expect(!set.coversWholeDomain)
        let id = try set.insert(raw: R(0, 5, 600), index: gop2Index, mode: .frame)
        #expect(!set.coversWholeDomain)
        try set.update(id: id, raw: R(0, 9, 600), index: gop2Index, mode: .frame)
        #expect(set.coversWholeDomain)
    }

    @Test func errorsHaveUserReadableMessages() {
        for e in [RangeSetError.emptyRange, .unknownID] as [any Error] + [SnapError.emptyIndex, ExportPlanError.empty] {
            let text = e.localizedDescription
            #expect(!text.isEmpty && !text.contains("SunshineCore") && !text.contains("error 0"), "\(text)")
        }
        #expect(ExportPlanError.empty.localizedDescription.hasPrefix("Nothing would be left to export"))
    }

    @Test func snapToggleNeverSplitsMergedRange() throws {
        // m9: merged under keyframe snapping, the raw spans (3.3, 4.9) and (6.2, 7.7) are disjoint,
        // but the merged range keeps one raw span (3.3, 8) and stays one range in frame mode.
        var set = RangeSet(domain: gop2Index.domain)
        try set.insert(raw: R(3.3, 4.9, 600), index: gop2Index, mode: .keyframe)
        // The inserted range's id survives a merge.
        let id = try set.insert(raw: R(6.2, 7.7, 600), index: gop2Index, mode: .keyframe)
        #expect(set.ranges.count == 1)
        #expect(set.ranges[0].id == id)
        try set.resnap(index: gop2Index, mode: .frame)
        #expect(set.ranges.count == 1)
        #expect(same(set.ranges[0].snapped, R(3.3, 8, 600)))
        try set.resnap(index: gop2Index, mode: .keyframe)
        #expect(set.ranges.count == 1)
        #expect(same(set.ranges[0].snapped, R(4, 8, 600)))
        #expect(set.ranges[0].id == id)
    }

    @Test func resnapMergesNewlyOverlappingRanges() throws {
        // Frame mode: (3.3, 3.9) and (4.1, 4.6) are disjoint; in keyframe mode both snap to (4, 6).
        var set = RangeSet(domain: gop2Index.domain)
        try set.insert(raw: R(3.3, 3.9, 600), index: gop2Index, mode: .frame)
        try set.insert(raw: R(4.1, 4.6, 600), index: gop2Index, mode: .frame)
        #expect(set.ranges.count == 2)
        try set.resnap(index: gop2Index, mode: .keyframe)
        #expect(set.ranges.count == 1)
        // raw (3.3, 4.6) widened by the snapped (4, 6).
        #expect(same(set.ranges[0].raw, R(3.3, 6, 600)))
    }

    @Test func noPrecisionLossAt1001Over30000() throws {
        let ts: CMTimeScale = 30000
        let index = makeIndex(ts: ts, frameDuration: 1001, count: 300, gop: 30)
        var set = RangeSet(domain: index.domain)
        try set.insert(raw: R(T(10 * 1001, ts), T(50 * 1001, ts)), index: index, mode: .frame)
        try set.insert(raw: R(T(40 * 1001, ts), T(97 * 1001, ts)), index: index, mode: .frame)
        try set.insert(raw: R(T(97 * 1001, ts), T(131 * 1001, ts)), index: index, mode: .frame)
        #expect(set.ranges.count == 1)
        let r = set.ranges[0]
        for t in [r.raw.start, r.raw.end, r.snapped.start, r.snapped.end] { #expect(t.timescale == ts) }
        #expect(r.snapped.start.value == 10 * 1001 && r.snapped.end.value == 131 * 1001)
        #expect(r.raw.start.value == 10 * 1001 && r.raw.end.value == 131 * 1001)
        #expect(r.snapped.duration.value == 121 * 1001 && r.snapped.duration.timescale == ts)
    }
}
