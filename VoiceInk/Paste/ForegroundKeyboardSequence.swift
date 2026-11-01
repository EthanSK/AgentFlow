// Extraction of existing CursorPaster.pasteFromClipboard and
// issueAutoSendUsingCGEvent key posting. The new behavior removes artificial
// inter-key/Return-hold padding; event sources, flags and one-shot boundaries stay.
import CoreGraphics

@MainActor
enum ForegroundKeyboardSequence {
    enum Outcome: Equatable {
        case posted, unavailable, actionGuardRefused, clipboardLeaseLost
    }

    // Extraction of the existing four Cmd-V events. The injectable emitter lets
    // unit tests inspect the real events without touching a desktop; production
    // always uses the default ordinary HID stream, never a process-targeted event.
    static func commandV(
        canPost: () -> Bool,
        ownsClipboard: (String) -> Bool,
        emit: (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) }
    ) -> Outcome {
        let source = CGEventSource(stateID: .privateState)
        guard let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: true),
              let vDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
              let vUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false),
              let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: false) else { return .unavailable }
        cmdDown.flags = .maskCommand
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand
        cmdUp.flags = []
        guard canPost() else { return .actionGuardRefused }
        guard ownsClipboard("beforeCommandDown") else { return .clipboardLeaseLost }
        emit(cmdDown)
        // Always balance the already-issued modifier if the final boundary fails.
        guard canPost() else { emit(cmdUp); return .actionGuardRefused }
        guard ownsClipboard("beforeVDown") else { emit(cmdUp); return .clipboardLeaseLost }
        emit(vDown)
        emit(vUp)
        emit(cmdUp)
        return .posted
    }

    // Extraction of the accepted HID-system Return, now without its old 30 ms
    // hold. Explicit flags preserve plain Enter, Shift-Enter and Command-Enter.
    static func returnKey(
        flags: CGEventFlags,
        canPost: () -> Bool,
        emit: (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) }
    ) -> Outcome {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: false) else { return .unavailable }
        down.flags = flags
        up.flags = flags
        guard canPost() else { return .actionGuardRefused }
        emit(down)
        emit(up)
        return .posted
    }
}
