import AVKit
import SwiftUI

struct PlayerView: View {
    @Environment(EditorModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            PlayerLayerView(player: model.playback.player)
                .disabled(!model.can(.playback))
            HStack {
                if model.isPreviewing, let mode = model.previewMode {
                    Label(mode == .keep ? "Previewing Keep" : "Previewing Remove", systemImage: "eye")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                }
                Spacer()
                Text(timeLabel)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
    }

    private var timeLabel: String {
        let span = model.timelineSpan
        let duration = span.duration.seconds
        let current = model.playback.currentSeconds - span.start.seconds
        let hours = duration >= 3600
        return "\(TimeFormat.clock(current, hours: hours)) / \(TimeFormat.clock(duration, hours: hours))"
    }
}

/// `AVPlayerView` with inline controls.
private struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = true
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

enum TimeFormat {
    /// `mm:ss`, or `h:mm:ss` when `hours` is set. Truncates to whole seconds.
    static func clock(_ seconds: Double, hours: Bool = false) -> String {
        let total = seconds.isFinite ? max(0, Int(seconds.rounded(.down))) : 0
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if hours || h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }

    /// Exact seconds with millisecond precision, for tooltips.
    static func precise(_ seconds: Double) -> String {
        String(format: "%.3f s", seconds)
    }
}
