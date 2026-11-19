import AppKit
import SwiftUI

/// One measurement for the Codex chat label, the card around it and its host window.
/// Keep the actual title (including its leading emoji) at reading size on every display.
struct RecorderChatBannerLayout {
    enum Placement { case controls, chip }
    static let fontSize: CGFloat = 18
    let text: String
    let textWidth: CGFloat
    let cardWidth: CGFloat
    let height: CGFloat
    let separateRow: Bool

    init(_ text: String, availableWidth: CGFloat, placement: Placement = .controls) {
        self.text = text
        let available = max(1, availableWidth)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: Self.fontSize, weight: .semibold)
        ]
        let string = text as NSString
        let natural = ceil(string.size(withAttributes: attributes).width) + 4
        let reserved: CGFloat = placement == .controls ? 360 : 80
        separateRow = placement == .controls && available - reserved < min(230, natural)
        let margins: CGFloat = separateRow ? 24 : reserved
        textWidth = max(1, min(natural, available - margins))
        cardWidth = min(available, max(separateRow ? 324 : 0, textWidth + margins))
        let bounds = string.boundingRect(
            with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes
        )
        let measured = ceil(bounds.height) + 4
        let controls = MiniRecorderLayoutMetrics.controlBarHeight
        height = separateRow ? controls + measured + 6 : max(controls, measured + 14)
    }

    static func chipExtraHeight(_ banner: String?, availableWidth: CGFloat) -> CGFloat {
        guard let banner else { return 0 }
        return Self(banner, availableWidth: availableWidth, placement: .chip).height
            - MiniRecorderLayoutMetrics.controlBarHeight
    }
}

struct RecorderChatBanner: View {
    let layout: RecorderChatBannerLayout

    var body: some View {
        Text(verbatim: layout.text)
            .font(.system(size: RecorderChatBannerLayout.fontSize, weight: .semibold))
            .foregroundStyle(.white)
            .multilineTextAlignment(.leading)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: layout.textWidth, alignment: .leading)
            .help(layout.text)
    }
}
