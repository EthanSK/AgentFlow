import SwiftUI
import AppKit
import OSLog
import Combine

class WindowManager: NSObject {
    static let shared = WindowManager()

    private static let mainWindowIdentifier = NSUserInterfaceItemIdentifier("com.prakashjoshipax.voiceink.mainWindow")
    private static let mainWindowFrameDefaultsKey = "VoiceInkMainWindowFrame"

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "WindowManager")
    private weak var mainWindow: NSWindow?
    private var didApplyInitialPlacement = false
    private var zoomObservation: AnyCancellable?
    private var zoomKeyMonitor: Any?
    private let zoomStore: MainWindowZoomStore
    private var appliedZoom: Double

    init(zoomStore: MainWindowZoomStore = .shared) {
        self.zoomStore = zoomStore
        self.appliedZoom = zoomStore.scale
        super.init()
        zoomObservation = zoomStore.$scale.dropFirst().sink { [weak self] scale in
            // @Published emits before the new value is stored. Resizing there
            // races SwiftUI's old minimum width, leaving a blank strip after
            // zoom-out. Apply only the latest value on the next main turn.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.zoomStore.scale == scale else { return }
                self.applyMainWindowZoom(scale)
            }
        }
        // The ordinary View menu owns the visible shortcuts; this local alias
        // also accepts Command-= on keyboards where + normally needs Shift.
        zoomKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let window = self?.mainWindow,
                  (event.window ?? NSApp.keyWindow) === window,
                  let action = MainWindowZoomAction.from(event, mainWindowIsKey: window.isKeyWindow)
            else { return event }
            self?.zoomStore.apply(action)
            return nil
        }
    }

    deinit {
        if let zoomKeyMonitor { NSEvent.removeMonitor(zoomKeyMonitor) }
    }
    
    func configureWindow(_ window: NSWindow) {
        if let existingWindow = NSApplication.shared.windows.first(where: { $0.identifier == Self.mainWindowIdentifier && $0 != window }) {
            logger.notice("configureWindow: duplicate detected, reusing existing window")
            window.close()
            existingWindow.makeKeyAndOrderFront(nil)
            return
        }
        logger.notice("configureWindow: registering main window")
        
        let requiredStyleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.styleMask.formUnion(requiredStyleMask)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        window.title = "Agent Flow"  // user-visible brand; the stable bundle ID keeps existing data and permissions.
        window.collectionBehavior = [.fullScreenPrimary]
        window.level = .normal
        window.isOpaque = false
        window.isMovableByWindowBackground = false
        window.contentMinSize = MainWindowLayout.minimumSize(at: zoomStore.scale)
        registerMainWindowIfNeeded(window)
        applyInitialPlacementIfNeeded(to: window)
        window.orderFrontRegardless()
    }

    private func applyMainWindowZoom(_ scale: Double) {
        let previous = appliedZoom
        appliedZoom = scale
        guard let window = mainWindow else { return }
        let oldFrame = window.frame
        let oldContent = window.contentRect(forFrameRect: oldFrame)
        let minimum = MainWindowLayout.minimumSize(at: scale)
        window.contentView?.layoutSubtreeIfNeeded()
        window.contentMinSize = minimum
        let size = NSSize(width: minimum.width,
                          height: max(minimum.height, oldContent.height * scale / previous))
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: oldFrame.minX, y: oldFrame.maxY - frame.height)
        if let screen = window.screen {
            frame.origin.x = max(screen.visibleFrame.minX,
                                 min(frame.origin.x, screen.visibleFrame.maxX - frame.width))
            frame.origin.y = max(screen.visibleFrame.minY,
                                 min(frame.origin.y, screen.visibleFrame.maxY - frame.height))
        }
        window.setFrame(frame, display: true)
        saveMainWindowFrame(window)
    }
    
    func registerMainWindow(_ window: NSWindow) {
        mainWindow = window
        appliedZoom = zoomStore.scale
        zoomStore.mainWindowIsKey = window.isKeyWindow
        window.identifier = Self.mainWindowIdentifier
        window.delegate = self
    }
    
    func showMainWindow(destination: ViewType? = nil) -> NSWindow? {
        guard let window = resolveMainWindow() else {
            return nil
        }
        
        window.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .navigateToDestination, object: nil,
            userInfo: ["destination": ViewType.openingDestination(requested: destination).rawValue])
        NSApplication.shared.activate(ignoringOtherApps: true)
        return window
    }
    
    func hideMainWindow() {
        guard let window = resolveMainWindow() else {
            return
        }
        window.orderOut(nil)
    }
    
    func currentMainWindow() -> NSWindow? {
        resolveMainWindow()
    }
    
    private func registerMainWindowIfNeeded(_ window: NSWindow) {
        // Only register the primary content window, identified by the hidden title bar style
        if window.identifier == nil || window.identifier != Self.mainWindowIdentifier {
            registerMainWindow(window)
        }
    }
    
    private func applyInitialPlacementIfNeeded(to window: NSWindow) {
        guard !didApplyInitialPlacement else { return }

        // SwiftUI's WindowGroup assigns a generated, view-type-based autosave key before this
        // accessor runs, and that key changes when the root view's generic type changes between
        // releases. Persist AppKit's own frame descriptor under one VoiceInk++ key instead so
        // position, size, and monitor survive signed upgrades without competing autosave owners.
        if let savedFrame = UserDefaults.standard.string(forKey: Self.mainWindowFrameDefaultsKey) {
            window.setFrame(from: savedFrame)
            logger.notice("applyInitialPlacement: restored stable main-window frame")
        } else if let screen = window.screen ?? NSScreen.main ?? NSScreen.screens.first {
            window.setFrame(
                Self.topRightFrame(
                    windowFrame: window.frame,
                    visibleFrame: screen.visibleFrame
                ),
                display: false
            )
            logger.notice("applyInitialPlacement: no saved frame; placed main window at top right")
        }

        didApplyInitialPlacement = true
        saveMainWindowFrame(window)
    }

    static func topRightFrame(
        windowFrame: NSRect,
        visibleFrame: NSRect,
        margin: CGFloat = 24
    ) -> NSRect {
        var frame = windowFrame
        frame.origin.x = max(
            visibleFrame.minX,
            visibleFrame.maxX - frame.width - margin
        )
        frame.origin.y = max(
            visibleFrame.minY,
            visibleFrame.maxY - frame.height - margin
        )
        return frame
    }

    private func saveMainWindowFrame(_ window: NSWindow) {
        guard didApplyInitialPlacement,
              window.identifier == Self.mainWindowIdentifier else { return }

        // Keep one explicit descriptor independent of WindowGroup's generated autosave name.
        UserDefaults.standard.set(
            window.frameDescriptor,
            forKey: Self.mainWindowFrameDefaultsKey
        )
    }
    
    private func resolveMainWindow() -> NSWindow? {
        if let window = mainWindow {
            return window
        }

        logger.notice("resolveMainWindow: weak ref is nil, searching \(NSApplication.shared.windows.count, privacy: .public) windows by identifier")

        if let window = NSApplication.shared.windows.first(where: { $0.identifier == Self.mainWindowIdentifier }) {
            logger.notice("resolveMainWindow: recovered window via identifier fallback")
            mainWindow = window
            window.delegate = self
            return window
        }

        let windowIDs = NSApplication.shared.windows.map { $0.identifier?.rawValue ?? "nil" }.joined(separator: ", ")
        logger.error("resolveMainWindow: FAILED — no window found with main identifier. Total windows: \(NSApplication.shared.windows.count, privacy: .public), identifiers: \(windowIDs, privacy: .public)")
        return nil
    }
}

extension WindowManager: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window.identifier == Self.mainWindowIdentifier {
            saveMainWindowFrame(window)
            logger.notice("windowWillClose: main window closing, clearing weak reference")
            window.orderOut(nil)
            mainWindow = nil
            zoomStore.mainWindowIsKey = false
            didApplyInitialPlacement = false
        }
    }
    
    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window.identifier == Self.mainWindowIdentifier else { return }
        NSApplication.shared.activate(ignoringOtherApps: true)
        zoomStore.mainWindowIsKey = true
    }

    func windowDidResignKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window.identifier == Self.mainWindowIdentifier else { return }
        zoomStore.mainWindowIsKey = false
    }

    func windowDidMove(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        saveMainWindowFrame(window)
    }

    func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        saveMainWindowFrame(window)
    }

    func windowDidChangeScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        saveMainWindowFrame(window)
    }
} 
