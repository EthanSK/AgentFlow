import AppKit
import Combine
import SwiftUI

/// One persisted size for every mirrored recorder panel. Keeping this separate
/// from recording state lets a size change redraw the HUD without starting,
/// stopping, or retargeting a session.
final class RecorderHUDScaleStore: ObservableObject {
    static let shared = RecorderHUDScaleStore()
    static let defaultScale = 0.85
    static let minimumScale = 0.5
    static let maximumScale = 1.0

    @Published private(set) var scale: Double
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "RecorderHUDScale") {
        self.defaults = defaults
        self.key = key
        scale = Self.sanitized(defaults.object(forKey: key) as? Double ?? Self.defaultScale)
    }

    func setScale(_ requested: Double) {
        let value = Self.sanitized(requested)
        guard value != scale else { return }
        scale = value
        defaults.set(value, forKey: key)
    }

    static func sanitized(_ value: Double) -> Double {
        guard value.isFinite else { return defaultScale }
        return min(maximumScale, max(minimumScale, value))
    }
}

/// `scaleEffect` shrinks only the pixels, leaving the transparent panel's old
/// click footprint. Map a full-size SwiftUI coordinate space into a genuinely
/// smaller AppKit host instead, as the Agentic Mouse HUD does.
/// Keep the actual AppKit host at that smaller size, but perform the content
/// transform inside SwiftUI: scaling an ancestor NSView's bounds rendered the
/// controls correctly while SwiftUI interpreted their clicks in unscaled space.
final class ScaledRecorderHostingView: NSView {
    private let hostingView: RecorderControlsHostingView
    private let content: AnyView
    private var renderedSize: NSSize?
    private var renderedScale: CGFloat?
    private(set) var scale: CGFloat

    init(rootView: AnyView, scale: CGFloat) {
        hostingView = RecorderControlsHostingView(rootView: rootView)
        content = rootView
        self.scale = scale
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(hostingView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func setScale(_ value: CGFloat) {
        guard value != scale else { return }
        scale = value
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let sourceSize = Self.sourceSize(for: frame.size, scale: scale)
        hostingView.frame = bounds
        guard renderedSize != bounds.size || renderedScale != scale else { return }
        renderedSize = bounds.size
        renderedScale = scale
        hostingView.rootView = AnyView(
            content
                .frame(width: sourceSize.width, height: sourceSize.height)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: bounds.width, height: bounds.height, alignment: .topLeading)
        )
    }

    static func sourceSize(for panelSize: NSSize, scale: CGFloat) -> NSSize {
        NSSize(width: panelSize.width / max(scale, 0.01),
               height: panelSize.height / max(scale, 0.01))
    }
}

/// This HUD deliberately stays nonactivating while another app owns keyboard
/// focus. NSHostingView's default first-mouse decision rejected plain SwiftUI
/// buttons under the scaled AppKit bounds (reproduced at 0.5 and 0.85). Accept
/// the owned click without activating the app; NSTextView still owns explicit
/// keyboard focus. A control click is never a background-window drag.
final class RecorderControlsHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
}

/// Explicit nonactivating drag space: the hosting view must not reinterpret a
/// Stop/Mic/editor click as a window drag. Put this only in blank control-bar
/// space, not over buttons or the selectable typing editor.
struct RecorderPanelDragSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> RecorderPanelDragView { RecorderPanelDragView() }
    func updateNSView(_ view: RecorderPanelDragView, context: Context) {}
}

final class RecorderPanelDragView: NSView {
    private var pointerStart: NSPoint?
    private var windowStart: NSPoint?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        guard let panel = window as? MiniRecorderPanel else { return }
        pointerStart = panel.convertPoint(toScreen: event.locationInWindow)
        windowStart = panel.frame.origin
    }

    override func mouseDragged(with event: NSEvent) {
        guard let panel = window as? MiniRecorderPanel,
              let pointerStart, let windowStart else { return }
        let current = panel.convertPoint(toScreen: event.locationInWindow)
        panel.wasDraggedByUser = true
        panel.setFrameOrigin(NSPoint(x: windowStart.x + current.x - pointerStart.x,
                                     y: windowStart.y + current.y - pointerStart.y))
    }

    override func mouseUp(with event: NSEvent) {
        pointerStart = nil
        windowStart = nil
    }
}
