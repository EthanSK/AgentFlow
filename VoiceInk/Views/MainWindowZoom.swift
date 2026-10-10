import SwiftUI

enum MainWindowLayout {
    // Four five-percentage-point zoom steps. This is the whole main app, not
    // RecorderHUDScale: changing History must never resize an active recorder.
    static let defaultZoom: CGFloat = 1.20
    static let logicalWidth: CGFloat = 950
    static let logicalMinimumHeight: CGFloat = 730
    static let minimumSize = CGSize(width: logicalWidth * defaultZoom,
                                    height: logicalMinimumHeight * defaultZoom)
}

/// Keep the existing page layouts in one logical coordinate space, then enlarge
/// both their pixels and the window's physical layout. Transform inside SwiftUI;
/// scaling ancestor NSView bounds previously broke the recorder's click targets.
struct MainWindowZoom: ViewModifier {
    func body(content: Content) -> some View {
        GeometryReader { geometry in
            content
                .frame(width: MainWindowLayout.logicalWidth,
                       height: geometry.size.height / MainWindowLayout.defaultZoom)
                .scaleEffect(MainWindowLayout.defaultZoom, anchor: .topLeading)
                .frame(width: geometry.size.width, height: geometry.size.height,
                       alignment: .topLeading)
        }
        .frame(width: MainWindowLayout.minimumSize.width)
        .frame(minHeight: MainWindowLayout.minimumSize.height)
    }
}
