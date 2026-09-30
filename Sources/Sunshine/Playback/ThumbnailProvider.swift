import AVFoundation
import Observation

/// Thumbnail strip images for one asset (the source, or one frozen preview composition).
/// Each instance owns its own `AVAssetImageGenerator`; regeneration is debounced and cancellable.
@MainActor
@Observable
final class ThumbnailProvider {
    /// One slot per tile, filled as images arrive.
    private(set) var images: [CGImage?] = []

    @ObservationIgnored let asset: AVAsset
    @ObservationIgnored private let span: CMTimeRange
    @ObservationIgnored private let generator: AVAssetImageGenerator
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var requestedCount = 0
    /// Number of generations started; handy when checking that resizes don't pile up work.
    @ObservationIgnored private(set) var generationCount = 0

    init(asset: AVAsset, span: CMTimeRange) {
        self.asset = asset
        self.span = span
        generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 160, height: 90)
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 2)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 2)
    }

    static func tileCount(forWidth width: CGFloat) -> Int {
        max(8, Int((width / 96).rounded(.down)))
    }

    /// Requests a strip of `count` tiles. Waits 300 ms so a live resize only generates once.
    func request(count: Int) {
        guard count > 0, count != requestedCount || images.isEmpty else { return }
        requestedCount = count
        cancel()
        task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await self?.generate(count: count)
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        generator.cancelAllCGImageGeneration()
    }

    private func generate(count: Int) async {
        generationCount += 1
        let duration = span.duration.seconds
        guard duration > 0 else { return }
        let times: [CMTime] = (0..<count).map { i in
            let offset = duration * (Double(i) + 0.5) / Double(count)
            return span.start + CMTime(seconds: offset, preferredTimescale: span.duration.timescale)
        }
        images = Array(repeating: nil, count: count)
        var slotForTime: [CMTime: Int] = [:]
        for (i, t) in times.enumerated() { slotForTime[t] = i }

        for await result in generator.images(for: times) {
            if Task.isCancelled { return }
            guard let slot = slotForTime[result.requestedTime], let image = try? result.image else { continue }
            if slot < images.count { images[slot] = image }
        }
    }
}
