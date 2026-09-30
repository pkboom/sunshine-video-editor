import CoreMedia
import Testing
@testable import SunshineCore

@Suite struct ComplementTests {
    // D = videoTrack.timeRange = [1 s, 11 s), deliberately not starting at 0. 30 fps, ts 600.
    let index = makeIndex(ts: 600, frameDuration: 20, count: 300, gop: 30, domainStart: 600)
    let ts: CMTimeScale = 600

    func complement(_ raws: [CMTimeRange]) throws -> [CMTimeRange] {
        var set = RangeSet(domain: index.domain)
        for r in raws { try set.insert(raw: r, index: index, mode: .frame) }
        return set.complement()
    }

    func expectSegments(_ actual: [CMTimeRange], _ expected: [CMTimeRange], sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(actual.count == expected.count, sourceLocation: sourceLocation)
        #expect(zip(actual, expected).allSatisfy(same), "\(actual) != \(expected)", sourceLocation: sourceLocation)
    }

    @Test func noRangesGivesDomain() throws {
        expectSegments(try complement([]), [index.domain])
    }

    @Test func rangeAtDomainStart() throws {
        expectSegments(try complement([R(1, 3, ts)]), [R(3, 11, ts)])
    }

    @Test func rangeEndingAtDomainEnd() throws {
        expectSegments(try complement([R(8, 11, ts)]), [R(1, 8, ts)])
    }

    @Test func twoRangesGiveThreeSegments() throws {
        expectSegments(try complement([R(6, 7, ts), R(2, 4, ts)]), [R(1, 2, ts), R(4, 6, ts), R(7, 11, ts)])
    }

    @Test func fullCoverageIsEmptyAndRemovePlanThrows() throws {
        var set = RangeSet(domain: index.domain)
        try set.insert(raw: R(0, 20, ts), index: index, mode: .frame)
        #expect(set.complement().isEmpty)
        #expect(throws: ExportPlanError.empty) { try ExportPlan(mode: .remove, ranges: set) }
    }
}
