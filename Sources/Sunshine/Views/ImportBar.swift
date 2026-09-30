import SwiftUI

struct ImportBar: View {
    @Environment(EditorModel.self) private var model

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 10) {
            Button("Open File…", systemImage: "folder") { model.presentOpenPanel() }
                .disabled(!model.can(.openFile))

            Divider().frame(height: 20)

            TextField("YouTube link", text: $model.urlText)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 200)
                .onSubmit { model.startDownload() }
                .disabled(!model.can(.download))

            if model.isDownloading {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.downloadLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let fraction = model.downloadFraction {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                }
                .frame(width: 200)
                Button("Cancel", role: .cancel) { model.cancelDownload() }
                    .disabled(!model.can(.cancelDownload))
            } else {
                Button("Download", systemImage: "arrow.down.circle") { model.startDownload() }
                    .disabled(!model.can(.download) || model.urlText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .controlSize(.regular)
    }
}
