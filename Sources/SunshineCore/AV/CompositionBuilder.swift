import AVFoundation
import CoreMedia

public enum CompositionBuilderError: Error, Equatable, LocalizedError {
    case cannotAddTrack

    public var errorDescription: String? {
        switch self {
        case .cannotAddTrack: "Couldn't prepare the edited video for preview or export."
        }
    }
}

/// Builds the one frozen composition that backs preview playback, preview thumbnails and export.
public enum CompositionBuilder {
    /// Runs on the caller's actor so the mutable composition never crosses isolation. The result is an
    /// immutable copy that must never be mutated.
    nonisolated(nonsending)
    public static func build(plan: ExportPlan, videoTrack: AVAssetTrack, audioTrack: AVAssetTrack?) async throws -> AVComposition {
        let (ts, transform) = try await videoTrack.load(.naturalTimeScale, .preferredTransform)
        let audioRange = try await audioTrack?.load(.timeRange)

        let mutable = AVMutableComposition()
        guard let video = mutable.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw CompositionBuilderError.cannotAddTrack
        }
        video.naturalTimeScale = ts
        video.preferredTransform = transform

        var audio: AVMutableCompositionTrack?
        if audioTrack != nil {
            guard let track = mutable.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw CompositionBuilderError.cannotAddTrack
            }
            audio = track
        }

        var cursor = CMTime(value: 0, timescale: ts)
        for seg in plan.segments {
            try video.insertTimeRange(seg, of: videoTrack, at: cursor)
            // Audio shares the video cursor, so a shorter audio track leaves silence instead of
            // shifting later segments.
            if let audioTrack, let audio, let audioRange {
                let a = seg.intersection(audioRange)
                if a.isValid, a.duration > .zero {
                    try audio.insertTimeRange(a, of: audioTrack, at: cursor + (a.start - seg.start))
                }
            }
            cursor = cursor + seg.duration
        }
        if let audio, audio.segments.isEmpty {
            mutable.removeTrack(audio)
        }

        return mutable.copy() as! AVComposition
    }
}
