import AppKit
import CoreMedia
import SunshineCore
import SwiftUI

/// Thumbnail strip with range editing (plan S4). Works in seconds on the timeline span;
/// `EditorModel` converts back to `CMTime` and snaps to real sample times.
struct TimelineView: View {
    @Environment(EditorModel.self) private var model

    private static let stripHeight: CGFloat = 64
    private static let edgeGrab: CGFloat = 6
    private static let clickSlop: CGFloat = 3

    private enum DragKind {
        case create(anchor: Double)
        case adjust(id: UUID, movingStart: Bool, fixed: Double)
        case seek
    }

    @State private var dragKind: DragKind?
    @State private var dragSeconds: Double = 0
    /// Displayed edges (seconds) that override a range's snapped edges; cleared with a
    /// 0.15 s animation after release so the range visibly settles onto the snapped edge.
    @State private var settling: [UUID: (start: Double, end: Double)] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            GeometryReader { geo in
                strip(width: geo.size.width)
            }
            .frame(height: Self.stripHeight)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            if model.isPreviewing {
                Text(model.previewMode == .keep ? "Preview — kept ranges joined" : "Preview — ranges removed")
                    .font(.headline)
            } else {
                Text("Timeline").font(.headline)
                Text("Drag to select a range. Drag an edge to adjust. Click to seek.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Snap to keyframes", isOn: Binding(
                get: { model.snapToKeyframes },
                set: { on in withAnimation(.easeOut(duration: 0.15)) { model.setSnapToKeyframes(on) } }
            ))
            .toggleStyle(.checkbox)
            .disabled(!model.can(.toggleSnap))
            .help("Off: frame-exact cuts. They play perfectly in QuickTime and Apple apps; some other players may show a flicker at joins.")
        }
    }

    // MARK: Strip

    private func strip(width: CGFloat) -> some View {
        let span = model.timelineSpan
        let mapper = Mapper(start: span.start.seconds, duration: span.duration.seconds, width: width)
        return ZStack(alignment: .topLeading) {
            ThumbnailStrip(provider: model.timelineThumbnails, width: width, height: Self.stripHeight)

            if !model.isPreviewing, let index = model.sampleIndex {
                KeyframeTicks(syncSeconds: index.syncPTS.map(\.seconds), mapper: mapper)
            }

            if !model.isPreviewing {
                ForEach(model.ranges) { range in
                    rangeView(range, mapper: mapper)
                }
                if case .create(let anchor) = dragKind {
                    selectionRect(from: mapper.x(anchor), to: mapper.x(dragSeconds), highlighted: true)
                }
            }

            Playhead(playback: model.playback, mapper: mapper, height: Self.stripHeight)

            if model.state == .indexing {
                indexingOverlay
            }
        }
        .frame(width: width, height: Self.stripHeight)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
        .contentShape(Rectangle())
        .gesture(dragGesture(mapper: mapper))
        .onContinuousHover { phase in
            if case .active(let point) = phase, edgeHit(at: point.x, mapper: mapper) != nil {
                NSCursor.resizeLeftRight.set()
            } else {
                NSCursor.arrow.set()
            }
        }
        .onChange(of: ThumbnailStrip.requestKey(model.timelineThumbnails, width: width), initial: true) {
            model.timelineThumbnails?.request(count: ThumbnailProvider.tileCount(forWidth: width))
        }
    }

    private func rangeView(_ range: MediaRange, mapper: Mapper) -> some View {
        var start = settling[range.id]?.start ?? range.snapped.start.seconds
        var end = settling[range.id]?.end ?? range.snapped.end.seconds
        if case .adjust(let id, let movingStart, _) = dragKind, id == range.id {
            let fixedShown = movingStart ? range.snapped.end.seconds : range.snapped.start.seconds
            start = min(fixedShown, dragSeconds)
            end = max(fixedShown, dragSeconds)
        }
        let playing = model.playback.playingRangeID == range.id
        return selectionRect(from: mapper.x(start), to: mapper.x(end), highlighted: playing)
            .help("\(TimeFormat.precise(range.snapped.start.seconds)) – \(TimeFormat.precise(range.snapped.end.seconds))")
    }

    private func selectionRect(from a: CGFloat, to b: CGFloat, highlighted: Bool) -> some View {
        let x = min(a, b), w = max(abs(b - a), 1)
        return ZStack {
            Rectangle().fill(Color.yellow.opacity(highlighted ? 0.4 : 0.28))
            Rectangle().strokeBorder(Color.yellow, lineWidth: 2)
            HStack {
                Capsule().fill(Color.yellow).frame(width: 4, height: 24)
                Spacer(minLength: 0)
                Capsule().fill(Color.yellow).frame(width: 4, height: 24)
            }
            .padding(.horizontal, 1)
        }
        .frame(width: w, height: Self.stripHeight)
        .offset(x: x)
    }

    private var indexingOverlay: some View {
        ZStack {
            Rectangle().fill(.black.opacity(0.45))
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Indexing…").foregroundStyle(.white)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: Gestures

    /// The range edge (if any) within `edgeGrab` points of `x`.
    private func edgeHit(at x: CGFloat, mapper: Mapper) -> (range: MediaRange, isStart: Bool)? {
        guard !model.isPreviewing, model.can(.editRanges) else { return nil }
        var best: (range: MediaRange, isStart: Bool, distance: CGFloat)?
        for range in model.ranges {
            for isStart in [true, false] {
                let edge = mapper.x(isStart ? range.snapped.start.seconds : range.snapped.end.seconds)
                let distance = abs(edge - x)
                if distance <= Self.edgeGrab, distance < (best?.distance ?? .infinity) {
                    best = (range, isStart, distance)
                }
            }
        }
        return best.map { ($0.range, $0.isStart) }
    }

    private func dragGesture(mapper: Mapper) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                if dragKind == nil {
                    dragKind = beginDrag(at: value.startLocation.x, mapper: mapper)
                }
                dragSeconds = mapper.seconds(value.location.x)
            }
            .onEnded { value in
                let kind = dragKind
                dragKind = nil
                let moved = hypot(value.translation.width, value.translation.height) >= Self.clickSlop
                let end = mapper.seconds(value.location.x)
                guard moved else {
                    model.seek(toSeconds: mapper.seconds(value.startLocation.x))
                    return
                }
                switch kind {
                case .create(let anchor):
                    if let id = model.addRange(from: anchor, to: end) {
                        settle(id, from: anchor, to: end)
                    }
                case .adjust(let id, let movingStart, let fixed):
                    let shown = model.ranges.first { $0.id == id }
                        .map { movingStart ? $0.snapped.end.seconds : $0.snapped.start.seconds } ?? fixed
                    model.updateRange(id: id, from: fixed, to: end)
                    if model.ranges.contains(where: { $0.id == id }) {
                        settle(id, from: shown, to: end)
                    }
                case .seek, nil:
                    model.seek(toSeconds: end)
                }
            }
    }

    private func beginDrag(at x: CGFloat, mapper: Mapper) -> DragKind {
        guard !model.isPreviewing, model.can(.editRanges) else { return .seek }
        if let hit = edgeHit(at: x, mapper: mapper) {
            let raw = hit.range.raw
            return .adjust(id: hit.range.id, movingStart: hit.isStart,
                           fixed: hit.isStart ? raw.end.seconds : raw.start.seconds)
        }
        return .create(anchor: mapper.seconds(x))
    }

    /// Shows the range at the release position, then animates it onto its snapped edges.
    private func settle(_ id: UUID, from a: Double, to b: Double) {
        settling[id] = (min(a, b), max(a, b))
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.15)) { _ = settling.removeValue(forKey: id) }
        }
    }
}

/// Converts between timeline seconds and x positions.
struct Mapper {
    let start: Double
    let duration: Double
    let width: CGFloat

    func x(_ seconds: Double) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat((seconds - start) / duration) * width
    }

    func seconds(_ x: CGFloat) -> Double {
        guard width > 0 else { return start }
        return start + Double(min(max(x / width, 0), 1)) * duration
    }
}

private struct ThumbnailStrip: View {
    let provider: ThumbnailProvider?
    let width: CGFloat
    let height: CGFloat

    static func requestKey(_ provider: ThumbnailProvider?, width: CGFloat) -> String {
        let id = provider.map { "\(ObjectIdentifier($0).hashValue)" } ?? "none"
        return "\(id)-\(ThumbnailProvider.tileCount(forWidth: width))"
    }

    var body: some View {
        let images = provider?.images ?? []
        let count = max(images.count, ThumbnailProvider.tileCount(forWidth: width))
        let tileWidth = width / CGFloat(count)
        HStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { i in
                if i < images.count, let image = images[i] {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: tileWidth, height: height)
                        .clipped()
                } else {
                    Rectangle()
                        .fill(Color.secondary.opacity(i.isMultiple(of: 2) ? 0.16 : 0.22))
                        .frame(width: tileWidth, height: height)
                }
            }
        }
        .frame(width: width, height: height, alignment: .leading)
    }
}

private struct KeyframeTicks: View {
    let syncSeconds: [Double]
    let mapper: Mapper

    var body: some View {
        Canvas { context, size in
            // The average spacing bounds the minimum, so skip the per-tick work when it's too dense.
            guard !syncSeconds.isEmpty, size.width / CGFloat(syncSeconds.count) >= 4 else { return }
            let xs = syncSeconds.map(mapper.x)
            // Only draw when every pair of ticks is at least 4 pt apart.
            let minSpacing = zip(xs, xs.dropFirst()).map { $1 - $0 }.min() ?? .infinity
            guard minSpacing >= 4 else { return }
            var path = Path()
            for x in xs {
                path.move(to: CGPoint(x: x, y: size.height - 8))
                path.addLine(to: CGPoint(x: x, y: size.height))
            }
            context.stroke(path, with: .color(.white.opacity(0.85)), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}

private struct Playhead: View {
    let playback: PlaybackController
    let mapper: Mapper
    let height: CGFloat

    var body: some View {
        let x = min(max(mapper.x(playback.currentSeconds), 0), mapper.width - 2)
        Rectangle()
            .fill(Color.red)
            .frame(width: 2, height: height)
            .offset(x: x)
            .allowsHitTesting(false)
    }
}
