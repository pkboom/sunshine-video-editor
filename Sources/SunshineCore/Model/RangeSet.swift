import CoreMedia
import Foundation

public enum RangeSetError: Error, Equatable, Sendable {
    /// The range has zero duration after clamping to the domain.
    case emptyRange
    case unknownID
}

extension RangeSetError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .emptyRange: "The selected range is empty or outside the video."
        case .unknownID: "That range no longer exists."
        }
    }
}

/// Sorted, non-overlapping user ranges inside the edit domain `D`.
///
/// Ranges that overlap or touch on their **snapped** times are merged. A merged
/// range's `snapped` is the union of the snap of its members' raw union and every
/// member's snapped span, so a merge never shrinks what was selected. Its `raw` is
/// widened to cover that union too, so a later re-snap can't collapse it, and one
/// raw span per range means re-snapping never splits it.
public struct RangeSet: Sendable {
    public let domain: CMTimeRange
    public private(set) var ranges: [MediaRange] = []

    public init(domain: CMTimeRange) {
        self.domain = domain
    }

    /// Inserts a range and merges it with its neighbors. Returns the id of the
    /// range that now contains it.
    @discardableResult
    public mutating func insert(raw: CMTimeRange, index: SampleIndex, mode: SnapMode) throws -> MediaRange.ID {
        let clamped = try clampedRaw(raw)
        let range = MediaRange(raw: clamped, snapped: try index.snap(clamped, mode: mode))
        var next = ranges
        next.append(range)
        ranges = try Self.merged(next, preferring: range.id, index: index, mode: mode)
        return range.id
    }

    /// Replaces the raw span of `id` and merges it with any ranges it now reaches.
    /// The updated range keeps its id.
    public mutating func update(id: MediaRange.ID, raw: CMTimeRange, index: SampleIndex, mode: SnapMode) throws {
        guard let i = ranges.firstIndex(where: { $0.id == id }) else { throw RangeSetError.unknownID }
        let clamped = try clampedRaw(raw)
        var next = ranges
        next[i].raw = clamped
        next[i].snapped = try index.snap(clamped, mode: mode)
        ranges = try Self.merged(next, preferring: id, index: index, mode: mode)
    }

    /// `insert(raw:)` from two edge times in either order (a reversed `CMTimeRange(start:end:)`
    /// is an invalid, zeroed range, so drags that go right-to-left should use this).
    @discardableResult
    public mutating func insert(from a: CMTime, to b: CMTime, index: SampleIndex, mode: SnapMode) throws -> MediaRange.ID {
        try insert(raw: .normalized(a, b), index: index, mode: mode)
    }

    /// `update(id:raw:)` from two edge times in either order.
    public mutating func update(id: MediaRange.ID, from a: CMTime, to b: CMTime, index: SampleIndex, mode: SnapMode) throws {
        try update(id: id, raw: .normalized(a, b), index: index, mode: mode)
    }

    public mutating func delete(id: MediaRange.ID) {
        ranges.removeAll { $0.id == id }
    }

    /// Re-snaps every range from its raw span, then merges any that now overlap.
    public mutating func resnap(index: SampleIndex, mode: SnapMode) throws {
        var next = ranges
        for i in next.indices {
            next[i].snapped = try index.snap(next[i].raw, mode: mode)
        }
        ranges = try Self.merged(next, preferring: nil, index: index, mode: mode)
    }

    /// True when the ranges cover all of `domain`, i.e. a Remove export would be empty.
    public var coversWholeDomain: Bool {
        !ranges.isEmpty && complement().isEmpty
    }

    /// The gaps between snapped ranges within `domain`, chronological, zero-length gaps dropped.
    public func complement() -> [CMTimeRange] {
        var result: [CMTimeRange] = []
        var cursor = domain.start
        for r in ranges {
            if CMTimeCompare(r.snapped.start, cursor) > 0 {
                result.append(CMTimeRange(start: cursor, end: r.snapped.start))
            }
            cursor = CMTime.maximum(cursor, r.snapped.end)
        }
        if CMTimeCompare(domain.end, cursor) > 0 {
            result.append(CMTimeRange(start: cursor, end: domain.end))
        }
        return result
    }

    private func clampedRaw(_ raw: CMTimeRange) throws -> CMTimeRange {
        let clamped = raw.clamped(to: domain)
        guard !clamped.isZeroDuration else { throw RangeSetError.emptyRange }
        return clamped
    }

    /// Sorts and merges overlapping/touching ranges until stable. A merged range keeps
    /// `preferred`'s id when it is a member, otherwise the id of its earliest member.
    private static func merged(_ input: [MediaRange], preferring preferred: MediaRange.ID?,
                               index: SampleIndex, mode: SnapMode) throws -> [MediaRange] {
        var current = input
        while true {
            current.sort { CMTimeCompare($0.snapped.start, $1.snapped.start) < 0 }
            var out: [MediaRange] = []
            var didMerge = false
            for r in current {
                if var last = out.last, last.snapped.overlapsOrTouches(r.snapped) {
                    let id = (r.id == preferred) ? r.id : last.id
                    let rawUnion = last.raw.union(r.raw)
                    let snapped = try index.snap(rawUnion, mode: mode).union(last.snapped).union(r.snapped)
                    last = MediaRange(id: id, raw: rawUnion.union(snapped), snapped: snapped)
                    out[out.count - 1] = last
                    didMerge = true
                } else {
                    out.append(r)
                }
            }
            current = out
            // A merged union can grow and reach a further neighbor, so sweep again.
            if !didMerge { return current }
        }
    }
}
