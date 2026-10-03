import AVFoundation
import CoreMedia

public enum SampleIndexError: Error, Equatable, LocalizedError {
    case noSamples
    case readerFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noSamples: "This video has no frames that can be edited."
        case .readerFailed(let reason): "Couldn't read the video's frames. \(reason)"
        }
    }
}

/// Builds a `SampleIndex` (all sample PTS + sync-sample PTS, in track time) for a video track.
///
/// C1 reads the sample table through `AVSampleCursor`. C2 (`AVAssetReader` passthrough) is used when
/// the track can't provide cursors, when any non-empty segment plays at a rate other than 1x, or when
/// `forceReader` is set. Both yield pre-edit-list media times (measured: the first keyframe of a `-bf 2`
/// file is at 2 frames), so both are mapped through the track's non-empty segments into track time.
public enum SampleIndexLoader {
    public static func load(asset: AVURLAsset, videoTrack: AVAssetTrack, forceReader: Bool = false) async throws -> SampleIndex {
        let (ts, domain, segments, canProvideCursors) = try await videoTrack.load(
            .naturalTimeScale, .timeRange, .segments, .canProvideSampleCursors)
        let mapped = segments.filter { !$0.isEmpty }
        let allUnitRate = mapped.allSatisfy {
            CMTimeCompare($0.timeMapping.source.duration, $0.timeMapping.target.duration) == 0
        }

        let media: [Sample]
        if !forceReader, allUnitRate, canProvideCursors, let cursor = try cursorSamples(videoTrack) {
            media = cursor
        } else {
            media = try readerSamples(asset: asset, videoTrack: videoTrack)
        }
        let samples = mapToTrackTime(media, segments: mapped, timescale: ts)
        try Task.checkCancellation()

        var all: [CMTime] = []
        var sync: [CMTime] = []
        all.reserveCapacity(samples.count)
        for s in samples.map({ Sample(pts: convert($0.pts, ts), isSync: $0.isSync) }).sorted(by: { $0.pts < $1.pts }) {
            // Dedupe equal track times: a sample can appear in two adjacent segments.
            if let last = all.last, CMTimeCompare(last, s.pts) == 0 {
                if s.isSync, sync.last.map({ CMTimeCompare($0, s.pts) != 0 }) ?? true { sync.append(s.pts) }
                continue
            }
            all.append(s.pts)
            if s.isSync { sync.append(s.pts) }
        }
        guard !all.isEmpty else { throw SampleIndexError.noSamples }

        let exactDomain = CMTimeRange(start: convert(domain.start, ts), end: convert(domain.end, ts))
        return SampleIndex(timescale: ts, allPTS: all, syncPTS: sync, domain: exactDomain)
    }

    struct Sample {
        var pts: CMTime
        var isSync: Bool
    }

    private static func convert(_ t: CMTime, _ ts: CMTimeScale) -> CMTime {
        t.timescale == ts ? t : CMTimeConvertScale(t, timescale: ts, method: .roundHalfAwayFromZero)
    }

    /// C1: media-time PTS in decode order. Returns nil if the track has no samples.
    ///
    /// `makeSampleCursorAtFirstSampleInDecodeOrder()` is not deprecated in the macOS 26 SDK; only the
    /// synchronous `canProvideSampleCursors` getter is, which is why that flag is read with `load`.
    private static func cursorSamples(_ track: AVAssetTrack) throws -> [Sample]? {
        guard let cursor = track.makeSampleCursorAtFirstSampleInDecodeOrder() else { return nil }
        var out: [Sample] = []
        var steps = 0
        repeat {
            steps += 1
            if steps % 4096 == 0 { try Task.checkCancellation() }
            let pts = cursor.presentationTimeStamp
            if pts.isNumeric {
                out.append(Sample(pts: pts, isSync: cursor.currentSampleSyncInfo.sampleIsFullSync.boolValue))
            }
        } while cursor.stepInDecodeOrder(byCount: 1) == 1
        return out
    }

    /// Maps media times through segments: `trackTime = target.start + (pts - source.start)` for `pts` in
    /// `source`, exact for 1x segments. Non-1x segments (C2 only) scale the offset by the segment rate and
    /// round to the track timescale. Samples in no segment are dropped.
    static func mapToTrackTime(_ media: [Sample], segments: [AVAssetTrackSegment], timescale ts: CMTimeScale) -> [Sample] {
        var out: [Sample] = []
        out.reserveCapacity(media.count)
        for seg in segments {
            let source = seg.timeMapping.source
            let target = seg.timeMapping.target
            let unitRate = CMTimeCompare(source.duration, target.duration) == 0
            let rate = target.duration.seconds / source.duration.seconds
            for s in media where source.containsTime(s.pts) {
                let offset = s.pts - source.start
                let scaled = unitRate ? offset : CMTime(seconds: offset.seconds * rate, preferredTimescale: ts)
                out.append(Sample(pts: target.start + scaled, isSync: s.isSync))
            }
        }
        return out
    }

    /// C2: passthrough reader. Output PTS are media times, like the cursor's.
    private static func readerSamples(asset: AVURLAsset, videoTrack: AVAssetTrack) throws -> [Sample] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw SampleIndexError.readerFailed("Can't read the video track.") }
        reader.add(output)
        guard reader.startReading() else {
            throw SampleIndexError.readerFailed(reader.error?.localizedDescription ?? "Can't start reading.")
        }
        var out: [Sample] = []
        while let buffer = output.copyNextSampleBuffer() {
            if Task.isCancelled {
                reader.cancelReading()
                throw CancellationError()
            }
            let count = CMSampleBufferGetNumSamples(buffer)
            guard count > 0 else { continue }
            let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[CFString: Any]]
            if count == 1 {
                let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
                if pts.isNumeric { out.append(Sample(pts: pts, isSync: !notSync(attachments?.first))) }
                continue
            }
            var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
            var filled = 0
            guard CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: count, arrayToFill: &timing, entriesNeededOut: &filled) == noErr else {
                continue
            }
            for i in 0..<min(filled, count) where timing[i].presentationTimeStamp.isNumeric {
                let a = attachments.flatMap { i < $0.count ? $0[i] : nil }
                out.append(Sample(pts: timing[i].presentationTimeStamp, isSync: !notSync(a)))
            }
        }
        guard reader.status == .completed else {
            throw SampleIndexError.readerFailed(reader.error?.localizedDescription ?? "Reading stopped early.")
        }
        return out
    }

    private static func notSync(_ attachment: [CFString: Any]?) -> Bool {
        (attachment?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false
    }
}
