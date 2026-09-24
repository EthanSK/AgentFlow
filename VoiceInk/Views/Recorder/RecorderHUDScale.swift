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
final class ScaledRecorderHostingView: NSView {
    private let hostingView: NSHostingView<AnyView>
    private(set) var scale: CGFloat

    init(rootView: AnyView, scale: CGFloat) {
        hostingView = NSHostingView(rootView: rootView)
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
        let sourceBounds = NSRect(origin: .zero, size: sourceSize)
        if bounds != sourceBounds { bounds = sourceBounds }
        hostingView.frame = sourceBounds
    }

    static func sourceSize(for panelSize: NSSize, scale: CGFloat) -> NSSize {
        NSSize(width: panelSize.width / max(scale, 0.01),
               height: panelSize.height / max(scale, 0.01))
    }
}
