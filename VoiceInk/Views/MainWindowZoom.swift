import SwiftUI
import AppKit

enum MainWindowLayout {
    // Main-app zoom is deliberately independent of RecorderHUDScale. Changing
    // History or Settings must never resize or refocus an active recorder.
    static let defaultZoom: CGFloat = 1
    static let logicalWidth: CGFloat = 950
    static let logicalMinimumHeight: CGFloat = 730
    static let minimumSize = CGSize(width: logicalWidth * defaultZoom,
                                    height: logicalMinimumHeight * defaultZoom)

    static func minimumSize(at scale: Double) -> CGSize {
        CGSize(width: logicalWidth * scale, height: logicalMinimumHeight * scale)
    }
}

/// The menu, keyboard shortcuts and content all read one persisted main-app
/// scale. The former fixed 120% transform offered no way to make History smaller.
final class MainWindowZoomStore: ObservableObject {
    static let shared = MainWindowZoomStore()
    static let minimumScale = 0.75
    static let maximumScale = 1.5
    static let defaultScale = 1.0
    @Published private(set) var scale: Double
    @Published var mainWindowIsKey = false
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "MainWindowZoom") {
        self.defaults = defaults
        self.key = key
        scale = Self.sanitized(defaults.object(forKey: key) as? Double ?? Self.defaultScale)
    }

    var percentage: Int { Int((scale * 100).rounded()) }
    var canZoomIn: Bool { scale < Self.maximumScale }
    var canZoomOut: Bool { scale > Self.minimumScale }

    func setScale(_ value: Double) {
        let next = Self.sanitized(value)
        guard next != scale else { return }
        scale = next
        defaults.set(next, forKey: key)
    }

    func apply(_ action: MainWindowZoomAction) {
        switch action {
        case .zoomIn: setScale((scale * 100 + 10).rounded() / 100)
        case .zoomOut: setScale((scale * 100 - 10).rounded() / 100)
        case .actualSize: setScale(Self.defaultScale)
        }
    }

    static func sanitized(_ value: Double) -> Double {
        value.isFinite ? min(maximumScale, max(minimumScale, value)) : defaultScale
    }
}

enum MainWindowZoomAction: Equatable {
    case zoomIn, zoomOut, actualSize

    static func from(_ event: NSEvent, mainWindowIsKey: Bool) -> Self? {
        // A local, main-window-only shortcut must never consume text or commands
        // from the floating recorder, another Agent Flow window or another app.
        guard mainWindowIsKey, event.type == .keyDown else { return nil }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard flags == .command || flags == [.command, .shift] else { return nil }
        switch event.charactersIgnoringModifiers {
        case "+", "=": return .zoomIn
        case "-", "_": return .zoomOut
        case "0" where flags == .command: return .actualSize
        default: return nil
        }
    }
}

struct MainWindowZoomMenu: View {
    @ObservedObject var store: MainWindowZoomStore = .shared
    var keyboardShortcuts = false

    private var unavailable: Bool { keyboardShortcuts && !store.mainWindowIsKey }

    var body: some View {
        Text("Zoom: \(store.percentage)%")
        Button("Zoom In") { store.apply(.zoomIn) }
            .keyboardShortcut(keyboardShortcuts ? KeyboardShortcut("+", modifiers: .command) : nil)
            .disabled(unavailable || !store.canZoomIn)
        Button("Zoom Out") { store.apply(.zoomOut) }
            .keyboardShortcut(keyboardShortcuts ? KeyboardShortcut("-", modifiers: .command) : nil)
            .disabled(unavailable || !store.canZoomOut)
        Button("Actual Size") { store.apply(.actualSize) }
            .keyboardShortcut(keyboardShortcuts ? KeyboardShortcut("0", modifiers: .command) : nil)
            .disabled(unavailable || store.scale == MainWindowZoomStore.defaultScale)
    }
}

/// Keep the existing page layouts in one logical coordinate space, then enlarge
/// both their pixels and the window's physical layout. Transform inside SwiftUI;
/// scaling ancestor NSView bounds previously broke the recorder's click targets.
struct MainWindowZoom: ViewModifier {
    @ObservedObject var store: MainWindowZoomStore = .shared

    func body(content: Content) -> some View {
        GeometryReader { geometry in
            content
                .frame(width: MainWindowLayout.logicalWidth,
                       height: geometry.size.height / store.scale)
                .scaleEffect(store.scale, anchor: .topLeading)
                .frame(width: geometry.size.width, height: geometry.size.height,
                       alignment: .topLeading)
        }
        .frame(width: MainWindowLayout.minimumSize(at: store.scale).width)
        .frame(minHeight: MainWindowLayout.minimumSize(at: store.scale).height)
    }
}
