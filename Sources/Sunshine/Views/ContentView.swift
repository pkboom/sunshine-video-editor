import SwiftUI

struct ContentView: View {
    @Environment(EditorModel.self) private var model
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            ImportBar()
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            if let banner = model.banner {
                ErrorBanner(message: banner)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
            Divider()
            if model.hasSource {
                editor
            } else {
                emptyState
            }
        }
        .background(.background)
        .dropDestination(for: URL.self) { urls, _ in
            model.handleDrop(urls)
        } isTargeted: { dropTargeted = $0 && model.can(.dropFile) }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
    }

    private var editor: some View {
        VStack(spacing: 0) {
            PlayerView()
                .frame(minHeight: 240)
                .layoutPriority(1)
            Divider()
            TimelineView()
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            Divider()
            HStack(alignment: .top, spacing: 0) {
                RangeListView()
                    .frame(minWidth: 260, maxWidth: 340)
                Divider()
                ExportBar()
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(height: 170)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Video", systemImage: "film")
        } description: {
            Text("Open a video file, drop one here, or download a YouTube link.")
        } actions: {
            Button("Open File…") { model.presentOpenPanel() }
                .disabled(!model.can(.openFile))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
