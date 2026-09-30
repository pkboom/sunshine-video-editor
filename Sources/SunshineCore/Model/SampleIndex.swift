import CoreMedia
import Foundation

public enum SnapMode: Sendable { case keyframe, frame }

public enum SnapError: Error, Equatable, Sendable {
    /// No sample (or sync sample, in keyframe mode) times are available.
    case emptyIndex
}

extension SnapError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .emptyIndex: "The video's frames haven't been indexed yet, so ranges can't be placed."
        }
    }
}

/// Presentation times of the video track, in track time and the track timescale.
public struct SampleIndex: Sendable {
    public let timescale: CMTimeScale
    /// Sorted, deduped presentation times of every sample.
    public let allPTS: [CMTime]
    /// Sorted subset of `allPTS` that are sync samples (keyframes).
    public let syncPTS: [CMTime]
    /// Edit domain `D = videoTrack.timeRange`.
    public let domain: CMTimeRange

    public init(timescale: CMTimeScale, allPTS: [CMTime], syncPTS: [CMTime], domain: CMTimeRange) {
        self.timescale = timescale
        self.allPTS = allPTS
        self.syncPTS = syncPTS
        self.domain = domain
    }

    /// Snaps `r` (normalized and clamped to `domain`) to sample times.
    ///
    /// Start goes to the nearest candidate PTS (ties go earlier). End goes to the
    /// nearest candidate PTS strictly after the snapped start, or to `domain.end`
    /// when that is nearer or no such PTS exists, so the result is never empty.
    /// Candidates are `syncPTS` for `.keyframe` and `allPTS` for `.frame`.
    public func snap(_ r: CMTimeRange, mode: SnapMode) throws -> CMTimeRange {
        let candidates = (mode == .keyframe ? syncPTS : allPTS).filter {
            CMTimeCompare($0, domain.start) >= 0 && CMTimeCompare($0, domain.end) < 0
        }
        guard !candidates.isEmpty else { throw SnapError.emptyIndex }
        let clamped = r.clamped(to: domain)

        let start = Self.nearest(to: clamped.start, in: candidates[...])
        let after = candidates[Self.firstIndex(after: start, in: candidates)...]
        var end = domain.end
        if !after.isEmpty {
            let pts = Self.nearest(to: clamped.end, in: after)
            if Self.isCloser(pts, than: domain.end, to: clamped.end, tieGoesToFirst: true) { end = pts }
        }
        return CMTimeRange(start: start, end: end)
    }

    /// Nearest element of the sorted, non-empty `times` to `t`; ties go earlier.
    static func nearest(to t: CMTime, in times: ArraySlice<CMTime>) -> CMTime {
        // First index with times[i] >= t.
        var lo = times.startIndex, hi = times.endIndex
        while lo < hi {
            let mid = (lo + hi) / 2
            if CMTimeCompare(times[mid], t) < 0 { lo = mid + 1 } else { hi = mid }
        }
        if lo == times.endIndex { return times[times.endIndex - 1] }
        if lo == times.startIndex { return times[lo] }
        let below = times[lo - 1], above = times[lo]
        return isCloser(above, than: below, to: t, tieGoesToFirst: false) ? above : below
    }

    /// First index with times[i] > t.
    static func firstIndex(after t: CMTime, in times: [CMTime]) -> Int {
        var lo = 0, hi = times.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if CMTimeCompare(times[mid], t) <= 0 { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    static func distance(_ a: CMTime, _ b: CMTime) -> CMTime {
        CMTimeAbsoluteValue(CMTimeSubtract(a, b))
    }

    /// Whether `a` is closer to `t` than `b`. On a tie, returns `tieGoesToFirst`.
    static func isCloser(_ a: CMTime, than b: CMTime, to t: CMTime, tieGoesToFirst: Bool) -> Bool {
        let c = CMTimeCompare(distance(a, t), distance(b, t))
        return c < 0 || (c == 0 && tieGoesToFirst)
    }
}
