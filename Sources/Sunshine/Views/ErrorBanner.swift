import SwiftUI

struct ErrorBanner: View {
    @Environment(EditorModel.self) private var model
    let message: BannerMessage

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: message.kind == .info ? "info.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(message.kind == .info ? Color.accentColor : Color.orange)
            Text(message.text)
                .textSelection(.enabled)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
            if message.kind == .tcc {
                Button("Open Privacy Settings") { model.openPrivacySettings() }
            }
            Button("Dismiss", systemImage: "xmark") { model.dismissBanner() }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        }
        .padding(10)
        .background(.orange.opacity(message.kind == .info ? 0 : 0.12), in: RoundedRectangle(cornerRadius: 8))
        .background(.quaternary.opacity(message.kind == .info ? 1 : 0), in: RoundedRectangle(cornerRadius: 8))
    }
}
