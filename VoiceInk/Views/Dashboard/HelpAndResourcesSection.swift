import SwiftUI

// Fork-owned destinations stay separate from upstream VoiceInk documentation.
// In particular, VoiceInk++ issue reports must not email upstream support or
// silently include system information; the Dashboard has an explicit Copy action.
enum VoiceInkPlusPlusResourceURLs {
    static let website = URL(string: "https://ethansk.github.io/VoiceInkPlusPlus/")!
    static let setupGuide = URL(string: "https://github.com/EthanSK/VoiceInkPlusPlus/blob/main/SETUP.md")!
    static let ethanSetup = URL(string: "https://ethansk.github.io/ethan-setup/")!
    static let agenticMouse = URL(string: "https://ethansk.github.io/agentic-mouse/")!
    static let issues = URL(string: "https://github.com/EthanSK/VoiceInkPlusPlus/issues")!
    static let originalVoiceInkDocs = URL(string: "https://tryvoiceink.com/docs")!
}

struct HelpAndResourcesSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Help & Resources")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)

            VStack(alignment: .leading, spacing: 10) {
                resourceLink(
                    icon: "waveform",
                    title: "VoiceInk++ website",
                    color: AppTheme.Sidebar.dashboard,
                    url: VoiceInkPlusPlusResourceURLs.website
                )

                resourceLink(
                    icon: "checklist",
                    title: "Full setup guide",
                    color: AppTheme.Sidebar.models,
                    url: VoiceInkPlusPlusResourceURLs.setupGuide
                )

                resourceLink(
                    icon: "desktopcomputer",
                    title: "Ethan's setup",
                    color: AppTheme.Sidebar.models,
                    url: VoiceInkPlusPlusResourceURLs.ethanSetup
                )

                resourceLink(
                    icon: "computermouse.fill",
                    title: "Agentic Mouse",
                    color: AppTheme.Sidebar.dictionary,
                    url: VoiceInkPlusPlusResourceURLs.agenticMouse
                )

                resourceLink(
                    icon: "exclamationmark.bubble.fill",
                    title: "Report a VoiceInk++ issue",
                    color: AppTheme.Sidebar.audio,
                    url: VoiceInkPlusPlusResourceURLs.issues
                )

                resourceLink(
                    icon: "book.fill",
                    title: "Original VoiceInk docs",
                    color: AppTheme.Sidebar.dictionary,
                    url: VoiceInkPlusPlusResourceURLs.originalVoiceInkDocs
                )
            }
        }
        .padding(18)
        .background(AppCardBackground(cornerRadius: 28))
    }
    
    private func resourceLink(icon: String, title: LocalizedStringKey, color: Color, url: URL) -> some View {
        Button(action: {
            NSWorkspace.shared.open(url)
        }) {
            HStack(spacing: 10) {
                DashboardIconGlyph(systemName: icon, color: color, size: 15, frameSize: 20)
                
                Text(title)
                    .font(.system(size: 13))
                    .fontWeight(.semibold)
                
                Spacer()
                
                Image(systemName: "arrow.up.right")
                    .foregroundColor(.secondary)
            }
            .padding(12)
            .background(AppTheme.Surface.subtle)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

        }
        .buttonStyle(.plain)
    }
}
