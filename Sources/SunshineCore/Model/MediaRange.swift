import CoreMedia
import Foundation

/// One user-selected span. `raw` keeps the unsnapped times the user chose, so
/// re-snapping (e.g. toggling snap mode) always starts from the same span;
/// `snapped` is the effective span used for display, plans and export.
public struct MediaRange: Identifiable, Sendable, Equatable {
    public let id: UUID
    public var raw: CMTimeRange
    public var snapped: CMTimeRange

    public init(id: UUID = UUID(), raw: CMTimeRange, snapped: CMTimeRange) {
        self.id = id
        self.raw = raw
        self.snapped = snapped
    }
}

// MARK: - CMTime helpers shared by the model

extension CMTime {
    static func minimum(_ a: CMTime, _ b: CMTime) -> CMTime { CMTimeCompare(a, b) <= 0 ? a : b }
    static func maximum(_ a: CMTime, _ b: CMTime) -> CMTime { CMTimeCompare(a, b) >= 0 ? a : b }
}

extension CMTimeRange {
    /// Range from `start` to `end`, swapped if reversed.
    static func normalized(_ a: CMTime, _ b: CMTime) -> CMTimeRange {
        CMTimeCompare(a, b) <= 0 ? CMTimeRange(start: a, end: b) : CMTimeRange(start: b, end: a)
    }

    /// Normalizes and clamps `self` to `domain`. May return a zero-duration range at a domain edge.
    func clamped(to domain: CMTimeRange) -> CMTimeRange {
        let n = CMTimeRange.normalized(start, end)
        let s = CMTime.minimum(CMTime.maximum(n.start, domain.start), domain.end)
        let e = CMTime.maximum(CMTime.minimum(n.end, domain.end), s)
        return CMTimeRange(start: s, end: e)
    }

    var isZeroDuration: Bool { CMTimeCompare(duration, .zero) <= 0 }

    /// Overlapping or touching (`a.end == b.start` counts).
    func overlapsOrTouches(_ other: CMTimeRange) -> Bool {
        CMTimeCompare(end, other.start) >= 0 && CMTimeCompare(other.end, start) >= 0
    }

    func union(_ other: CMTimeRange) -> CMTimeRange {
        CMTimeRange(start: CMTime.minimum(start, other.start), end: CMTime.maximum(end, other.end))
    }
}
