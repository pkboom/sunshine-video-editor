import CoreMedia
import Testing
@testable import SunshineCore

@Suite struct ExportPlanTests {
    // 29.97 fps, ts 30000, 300 frames: D = [0, 300 * 1001).
    let ts: CMTimeScale = 30000
    let index = makeIndex(ts: 30000, frameDuration: 1001, count: 300, gop: 30)

    func frames(_ a: Int64, _ b: Int64) -> CMTimeRange { R(T(a * 1001, ts), T(b * 1001, ts)) }

    func set(_ raws: [CMTimeRange]) throws -> RangeSet {
        var s = RangeSet(domain: index.domain)
        for r in raws { try s.insert(raw: r, index: index, mode: .frame) }
        return s
    }

    @Test func keepIsChronologicalRegardlessOfInsertOrder() throws {
        let plan = try ExportPlan(mode: .keep, ranges: set([frames(200, 250), frames(10, 20), frames(100, 130)]))
        #expect(plan.mode == .keep)
        #expect(plan.segments.count == 3)
        #expect(zip(plan.segments, [frames(10, 20), frames(100, 130), frames(200, 250)]).allSatisfy(same))
    }

    @Test func removeIsComplement() throws {
        let s = try set([frames(200, 250), frames(10, 20)])
        let plan = try ExportPlan(mode: .remove, ranges: s)
        #expect(plan.mode == .remove)
        #expect(plan.segments == s.complement())
        #expect(zip(plan.segments, [frames(0, 10), frames(20, 200), frames(250, 300)]).allSatisfy(same))
    }

    @Test func totalDurationIsExactSum() throws {
        let keep = try ExportPlan(mode: .keep, ranges: set([frames(200, 250), frames(10, 20), frames(100, 131)]))
        #expect(CMTimeCompare(keep.totalDuration, T((50 + 10 + 31) * 1001, ts)) == 0)
        #expect(keep.totalDuration.timescale == ts)

        let remove = try ExportPlan(mode: .remove, ranges: set([frames(200, 250), frames(10, 20), frames(100, 131)]))
        #expect(CMTimeCompare(remove.totalDuration, T((300 - 91) * 1001, ts)) == 0)
        #expect(CMTimeCompare(CMTimeAdd(keep.totalDuration, remove.totalDuration), index.domain.duration) == 0)
    }

    @Test func segmentsAreNonEmptyAndInsideDomain() throws {
        let plan = try ExportPlan(mode: .remove, ranges: set([frames(0, 10), frames(290, 300)]))
        #expect(plan.segments.count == 1)
        for seg in plan.segments {
            #expect(CMTimeCompare(seg.duration, .zero) > 0)
            #expect(CMTimeRangeContainsTimeRange(index.domain, otherRange: seg))
        }
    }

    @Test func emptyKeepThrows() throws {
        #expect(throws: ExportPlanError.empty) { try ExportPlan(mode: .keep, ranges: set([])) }
    }
}
