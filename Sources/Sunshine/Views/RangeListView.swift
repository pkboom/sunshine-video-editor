import SunshineCore
import SwiftUI

struct RangeListView: View {
    @Environment(EditorModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Ranges")
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 6)
            if model.ranges.isEmpty {
                Text(model.state == .indexing ? "Indexing keyframes…" : "No ranges yet. Drag across the timeline to add one.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                Spacer(minLength: 0)
            } else {
                List {
                    ForEach(model.ranges) { range in
                        row(range)
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func row(_ range: MediaRange) -> some View {
        let hours = model.domain.duration.seconds >= 3600
        let playing = model.playback.playingRangeID == range.id
        return HStack(spacing: 8) {
            Button {
                model.play(range: range)
            } label: {
                Image(systemName: playing ? "speaker.wave.2.fill" : "play.fill")
            }
            .buttonStyle(.borderless)
            .disabled(!model.can(.rangePlay))
            .help("Play this range")

            Text("\(TimeFormat.clock(range.snapped.start.seconds, hours: hours))–\(TimeFormat.clock(range.snapped.end.seconds, hours: hours))")
                .font(.body.monospacedDigit())
                .help("\(TimeFormat.precise(range.snapped.start.seconds)) – \(TimeFormat.precise(range.snapped.end.seconds))")

            Spacer()

            Button {
                withAnimation(.easeOut(duration: 0.15)) { model.deleteRange(id: range.id) }
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .disabled(!model.can(.editRanges))
            .help("Delete this range")
        }
    }
}
