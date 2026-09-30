import CoreMedia
import Foundation

public enum ExportMode: Sendable { case keep, remove }

public enum ExportPlanError: Error, Equatable, Sendable {
    /// Keep with no ranges, or Remove covering the whole domain.
    case empty
}

extension ExportPlanError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .empty: "Nothing would be left to export — select at least one range, and for Remove leave part of the video unselected."
        }
    }
}

/// The source segments an export joins, in order.
public struct ExportPlan: Sendable, Equatable {
    public let mode: ExportMode
    /// Chronological, non-empty, inside the edit domain.
    public let segments: [CMTimeRange]
    /// Exact sum of the segment durations.
    public let totalDuration: CMTime

    public init(mode: ExportMode, ranges: RangeSet) throws {
        let source: [CMTimeRange]
        switch mode {
        case .keep: source = ranges.ranges.map(\.snapped)
        case .remove: source = ranges.complement()
        }
        let segments = source
            .filter { !$0.isZeroDuration }
            .sorted { CMTimeCompare($0.start, $1.start) < 0 }
        guard !segments.isEmpty else { throw ExportPlanError.empty }
        self.mode = mode
        self.segments = segments
        self.totalDuration = segments.reduce(CMTime(value: 0, timescale: ranges.domain.duration.timescale)) {
            CMTimeAdd($0, $1.duration)
        }
    }
}
