import SunshineCore
import SwiftUI

struct ExportBar: View {
    @Environment(EditorModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                if model.isPreviewing {
                    Button("Exit Preview", systemImage: "eye.slash") { model.exitPreview() }
                        .disabled(!model.can(.exitPreview))
                } else {
                    Button("Preview Keep") { model.enterPreview(.keep) }
                        .disabled(!canPreview)
                    Button("Preview Remove") { model.enterPreview(.remove) }
                        .disabled(!canPreview || !model.canRemove)
                        .help(model.canRemove ? "" : "The ranges cover the whole video, so nothing would be left")
                }
                Spacer()
                Button("Export Keep") { model.export(.keep) }
                    .disabled(!canExport(.keep))
                    .help("Save only the selected ranges, joined in order")
                Button("Export Remove", systemImage: "square.and.arrow.up") { model.export(.remove) }
                    .labelStyle(.titleOnly)
                    .disabled(!canExport(.remove) || !model.canRemove)
                    .help(model.canRemove ? "Save the whole video without the selected ranges"
                                          : "The ranges cover the whole video, so nothing would be left")
            }

            if model.isExporting {
                HStack(spacing: 10) {
                    ProgressView(value: model.exportProgress) {
                        Text("Exporting… \(Int((model.exportProgress * 100).rounded()))%")
                            .font(.callout)
                    }
                    Button("Cancel Export", role: .cancel) { model.cancelExport() }
                        .disabled(!model.can(.cancelExport))
                }
            } else if let url = model.exportedURL {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Saved \(url.lastPathComponent)")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Show in Finder") { model.showExportInFinder() }
                    Button("Dismiss", systemImage: "xmark") { model.dismissExportResult() }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                }
                .padding(10)
                .background(.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            } else {
                Text(hint)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var canPreview: Bool { model.can(.enterPreview) && !model.ranges.isEmpty }

    private func canExport(_ mode: ExportMode) -> Bool {
        guard model.can(.export), !model.ranges.isEmpty else { return false }
        // While previewing, export exactly the composition on screen.
        return !model.isPreviewing || model.previewMode == mode
    }

    private var hint: String {
        if model.isPreviewing { return "Exporting now saves exactly what you're previewing." }
        return "Keep saves only the selected ranges. Remove saves everything else. Cuts are lossless; the file is saved next to the source as “-edited.mp4”."
    }
}
