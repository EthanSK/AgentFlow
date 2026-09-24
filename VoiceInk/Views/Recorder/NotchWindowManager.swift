import SwiftUI
import AppKit
import Combine

@MainActor
class NotchWindowManager {
    private struct WindowEntry {
        let screenIdentity: RecorderDisplayReusePolicy.ScreenIdentity
        let panel: NotchRecorderPanel
        let host: ScaledRecorderHostingView
        let windowController: NSWindowController
    }

    private var windows: [WindowEntry] = []
    private let hudScale = RecorderHUDScaleStore.shared
    private var scaleSubscription: AnyCancellable?

    private let makeView: (_ notchWidth: CGFloat, _ notchHeight: CGFloat, _ screenHeight: CGFloat) -> AnyView

    init(
        engine: VoiceInkEngine,
        recorder: Recorder,
        assistantSession: AssistantSession,
        onRecordButtonTapped: @escaping () -> Void,
        onCloseTapped: @escaping () -> Void,
        // onCancelTapped: red "X" → stop without paste, retain audio/HUD draft in
        // History, and resume paused media. Permanent deletion remains explicit.
        onCancelTapped: @escaping () -> Void,
        onAssistantFollowUp: @escaping (String) -> Void,
        // onCancelSession: per-card cancel for a SPECIFIC background transcribing session
        // (record-while-transcribing stack). Routed to engine.cancelSession(id:).
        onCancelSession: @escaping (UUID) -> Void
    ) {
        self.makeView = { notchWidth, notchHeight, screenHeight in
            AnyView(
                // Host the STACK container: the active session is the notch pill, background
                // transcribing sessions render as chips stacked beneath it.
                NotchRecorderStackView(
                    engine: engine,
                    hudScale: RecorderHUDScaleStore.shared,
                    recorder: recorder,
                    assistantSession: assistantSession,
                    notchWidth: notchWidth,
                    notchHeight: notchHeight,
                    screenHeight: screenHeight,
                    onRecordButtonTapped: onRecordButtonTapped,
                    onCloseTapped: onCloseTapped,
                    onCancelTapped: onCancelTapped,
                    onAssistantFollowUp: onAssistantFollowUp,
                    onCancelSession: onCancelSession
                )
            )
        }
        scaleSubscription = hudScale.$scale.dropFirst().sink { [weak self] _ in
            self?.refreshScale()
        }
    }

    @discardableResult
    func show() -> RecorderPanelPresentationReport {
        let screens = NSScreen.screens
        let currentDisplayIDs = screens.enumerated().map { index, screen in
            RecorderDisplayReusePolicy.screenIdentity(for: screen, index: index)
        }
        let existingDisplayIDs = windows.map(\.screenIdentity)

        switch RecorderDisplayReusePolicy.windowSetPlan(
            existingDisplayIDs: existingDisplayIDs,
            currentDisplayIDs: currentDisplayIDs
        ) {
        case .keepExisting:
            return RecorderPanelPresentationReport(
                expectedScreenCount: 0,
                materializedPanelCount: windows.count,
                visibleOnScreenPanelCount: 0
            )
        case .rebuild:
            // Match MiniWindowManager's reuse boundary. Each notch panel owns a full
            // SwiftUI hierarchy, so rebuild only for a real display-set change.
            initializeWindows(screens: screens)
            return presentationReport(for: screens)
        case .reuse:
            for (entry, screen) in zip(windows, screens) {
                entry.host.setScale(CGFloat(hudScale.scale))
                entry.panel.show(on: screen, scale: CGFloat(hudScale.scale))
            }
            return presentationReport(for: screens)
        }
    }

    func hide() {
        windows.forEach { $0.panel.orderOut(nil) }
    }

    private func refreshScale() {
        guard !windows.isEmpty else { return }
        let screens = NSScreen.screens
        let identities = screens.enumerated().map { index, screen in
            RecorderDisplayReusePolicy.screenIdentity(for: screen, index: index)
        }
        guard identities == windows.map(\.screenIdentity) else {
            if windows.contains(where: { $0.panel.isVisible }) { _ = show() }
            return
        }
        for (entry, screen) in zip(windows, screens) {
            entry.host.setScale(CGFloat(hudScale.scale))
            if entry.panel.isVisible {
                entry.panel.show(on: screen, scale: CGFloat(hudScale.scale))
            }
        }
    }

    func destroyWindow() {
        deinitializeWindows()
    }

    private func initializeWindows(screens: [NSScreen] = NSScreen.screens) {
        deinitializeWindows()

        for (index, screen) in screens.enumerated() {
            let metrics = NotchRecorderPanel.calculateWindowMetrics(
                for: screen, scale: CGFloat(hudScale.scale)
            )
            let panel = NotchRecorderPanel(contentRect: metrics.frame)
            let view = makeView(metrics.notchWidth, metrics.notchHeight, screen.frame.height)
            let host = ScaledRecorderHostingView(rootView: view, scale: CGFloat(hudScale.scale))
            panel.contentView = host
            let windowController = NSWindowController(window: panel)
            windows.append(WindowEntry(
                screenIdentity: RecorderDisplayReusePolicy.screenIdentity(
                    for: screen,
                    index: index
                ),
                panel: panel,
                host: host,
                windowController: windowController
            ))
            panel.show(on: screen, scale: CGFloat(hudScale.scale))
        }
    }

    private func presentationReport(for screens: [NSScreen]) -> RecorderPanelPresentationReport {
        let screensByIdentity = Dictionary(
            screens.enumerated().map { index, screen in
                (RecorderDisplayReusePolicy.screenIdentity(for: screen, index: index), screen)
            },
            uniquingKeysWith: { first, _ in first }
        )
        let currentEntries = windows.filter { screensByIdentity[$0.screenIdentity] != nil }
        let visibleOnScreenCount = currentEntries.reduce(into: 0) { count, entry in
            guard let screen = screensByIdentity[entry.screenIdentity] else { return }
            if entry.panel.isVisible && entry.panel.frame.intersects(screen.frame) {
                count += 1
            }
        }

        return RecorderPanelPresentationReport(
            expectedScreenCount: screens.count,
            materializedPanelCount: currentEntries.count,
            visibleOnScreenPanelCount: visibleOnScreenCount
        )
    }

    private func deinitializeWindows() {
        windows.forEach {
            $0.panel.orderOut(nil)
            $0.windowController.close()
        }
        windows.removeAll()
    }

}
