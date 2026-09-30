import AVFoundation
import Observation

/// Owns the single `AVPlayer`, publishes the current time for the UI, and implements
/// range play through `forwardPlaybackEndTime` (plan S4).
@MainActor
@Observable
final class PlaybackController {
    let player = AVPlayer()

    /// Current playhead in seconds (UI boundary only), refreshed every 0.25 s.
    private(set) var currentSeconds: Double = 0
    /// The range currently being played by ▶, if any.
    private(set) var playingRangeID: UUID?

    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var itemObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var rateObservation: NSKeyValueObservation?
    /// The span of the range being played by ▶.
    @ObservationIgnored private var playingRange: CMTimeRange?
    /// Set from ▶ until its seek to the range start completes. The pause and time jump that ▶
    /// itself causes (possibly observed late, from a position past the range) must not end range play.
    @ObservationIgnored private var rangePlaySeekPending = false
    /// Bumped by every ▶ so only the latest ▶'s seek completion acts, even for the same range.
    @ObservationIgnored private var rangePlayToken = 0

    init() {
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 4), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                self?.currentSeconds = time.isNumeric ? time.seconds : 0
            }
        }
        // KVO may fire on any thread: handle it in place on main, otherwise hop to the main actor.
        rateObservation = player.observe(\.rate, options: [.new]) { [weak self] player, _ in
            guard player.rate == 0 else { return }
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.playbackStopped() }
            } else {
                Task { @MainActor [weak self] in self?.playbackStopped() }
            }
        }
    }

    /// Replaces the player item (source asset or a frozen preview composition) and seeks to `time`.
    func load(asset: AVAsset?, at time: CMTime = .zero) {
        resetRangePlay()
        itemObservers.forEach(NotificationCenter.default.removeObserver)
        itemObservers = []
        player.pause()
        guard let asset else {
            player.replaceCurrentItem(with: nil)
            currentSeconds = 0
            return
        }
        let item = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: item)
        let center = NotificationCenter.default
        itemObservers.append(center.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.resetRangePlay() }
        })
        itemObservers.append(center.addObserver(
            forName: AVPlayerItem.timeJumpedNotification, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.timeJumped() }
        })
        if time != .zero { seek(to: time) }
        currentSeconds = time.isNumeric ? time.seconds : 0
    }

    var currentTime: CMTime { player.currentTime() }

    /// Manual seek (timeline click). Zero tolerance so the frame shown is the one clicked.
    func seek(to time: CMTime) {
        resetRangePlay()
        performSeek(to: time) { _ in }
    }

    /// ▶ on a range: play `range` and stop at its end.
    func play(range: CMTimeRange, id: UUID) {
        guard let item = player.currentItem else { return }
        resetRangePlay()
        player.pause()
        item.forwardPlaybackEndTime = range.end
        playingRangeID = id
        playingRange = range
        rangePlaySeekPending = true
        rangePlayToken += 1
        let token = rangePlayToken
        performSeek(to: range.start) { [weak self] finished in
            guard let self, self.rangePlayToken == token, self.playingRangeID == id else { return }
            self.rangePlaySeekPending = false
            guard finished else {
                // Superseded (e.g. by a scrub in the player controls): don't leave range play armed.
                self.resetRangePlay()
                return
            }
            self.player.play()
        }
    }

    /// Clears any range-play end time. Called on end, manual seek, new ▶ and preview entry/exit.
    func resetRangePlay() {
        player.currentItem?.forwardPlaybackEndTime = .invalid
        playingRangeID = nil
        playingRange = nil
        rangePlaySeekPending = false
    }

    func pause() { player.pause() }

    private func performSeek(to time: CMTime, completion: @escaping @MainActor (Bool) -> Void) {
        currentSeconds = time.isNumeric ? time.seconds : currentSeconds
        // The seek completion handler's queue isn't documented, so hop explicitly.
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
            Task { @MainActor in completion(finished) }
        }
    }

    /// A scrub in the player's own controls that leaves the playing range ends range play.
    /// (Our own seek to the range start also posts a time jump, which lands inside the range.)
    private func timeJumped() {
        guard let range = playingRange, !rangePlaySeekPending else { return }
        let slack = CMTime(value: 1, timescale: 30)
        let now = player.currentTime()
        if CMTimeCompare(now + slack, range.start) < 0 || CMTimeCompare(now, range.end) > 0 {
            resetRangePlay()
        }
    }

    /// The player stopped: if a ▶ range reached its end, clear the range-play end time.
    private func playbackStopped() {
        guard playingRangeID != nil, !rangePlaySeekPending, let item = player.currentItem else { return }
        let end = item.forwardPlaybackEndTime
        guard end.isValid else { return }
        // Within one 30 fps frame of the end counts as "reached the end".
        let slack = CMTime(value: 1, timescale: 30)
        if CMTimeCompare(player.currentTime() + slack, end) >= 0 {
            resetRangePlay()
        }
    }
}
