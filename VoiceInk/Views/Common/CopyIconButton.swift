import SwiftUI

struct CopyIconButton: View {
    let textToCopy: String
    var systemImage: String = "doc.on.doc"
    var title: String? = nil
    var accessibilityTitle: String = "Copy"
    var textTransform: (String) -> String = { $0 }
    @State private var copied = false

    var body: some View {
        Button(action: copy) {
            HStack(spacing: 6) {
                Image(systemName: copied ? "checkmark" : systemImage)
                if let title { Text(title) }
            }
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(copied ? AppTheme.Status.positive : AppTheme.Selection.foreground)
                .frame(width: title == nil ? 28 : 142, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous)
                        .fill(AppTheme.Surface.window.opacity(0.92))
                        .overlay {
                            RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous)
                                .strokeBorder(AppTheme.Border.card, lineWidth: 1)
                        }
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityTitle)
        .help(title == nil ? accessibilityTitle : "")
    }

    private func copy() {
        guard ClipboardManager.copyToClipboard(textTransform(textToCopy)) else { return }
        withAnimation { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation { copied = false }
        }
    }
}
