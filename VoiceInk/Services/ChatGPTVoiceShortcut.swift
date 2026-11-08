import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Which binding one ChatGPT Voice toggle may use. Ownership remembers it, so the inverse toggle
/// is always posted under the same authority as the toggle it pairs.
///
/// Local capture keeps its exact accepted `F20` contract: a Mac whose user never set that binding
/// has not asked Agent Flow to touch ChatGPT for its own recordings, and this feature must not
/// change that. A paired recipient opted in explicitly, and the binding it already has for this
/// one command is what ChatGPT there actually listens for, so that Mac's own validated binding is
/// used rather than requiring it to replace a shortcut its user chose.
enum ChatGPTVoiceShortcutAuthority: Equatable, Sendable {
    case acceptedLocalBinding
    case deviceConfiguredBinding
}

enum ChatGPTVoiceShortcutResolution: Equatable, Sendable {
    case resolved(ChatGPTVoiceShortcut)
    /// No usable keybinding entry exists for the command.
    case missing
    /// A binding exists, but posting it could not be trusted to run exactly that one command.
    case unsupported
}

/// One validated keyboard chord. This type only describes a chord; it can never post one, and it
/// only ever comes from a binding for the real microphone command, so no setting can turn this
/// path into arbitrary input.
struct ChatGPTVoiceShortcut: Equatable, Sendable {
    let virtualKey: CGKeyCode
    let flags: CGEventFlags
    /// The character `virtualKey` must produce for this to be the configured chord. `nil` for
    /// function keys, whose virtual key does not depend on the keyboard layout.
    let layoutCharacter: String?

    /// Private so a chord can only be the accepted constant or the result of parsing a binding.
    private init(virtualKey: CGKeyCode, flags: CGEventFlags, layoutCharacter: String?) {
        self.virtualKey = virtualKey
        self.flags = flags
        self.layoutCharacter = layoutCharacter
    }

    /// `Command+Control+Option+Shift+F20`, the accepted chord for local capture.
    static let acceptedLocal = ChatGPTVoiceShortcut(
        virtualKey: CGKeyCode(kVK_F20),
        flags: [.maskCommand, .maskControl, .maskAlternate, .maskShift],
        layoutCharacter: nil
    )

    private static let modifierFlags: [String: CGEventFlags] = [
        "command": .maskCommand, "cmd": .maskCommand, "super": .maskCommand, "meta": .maskCommand,
        "commandorcontrol": .maskCommand, "cmdorctrl": .maskCommand,
        "control": .maskControl, "ctrl": .maskControl,
        "option": .maskAlternate, "alt": .maskAlternate,
        "shift": .maskShift
    ]

    private static let functionKeys: [String: Int] = [
        "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4, "f5": kVK_F5,
        "f6": kVK_F6, "f7": kVK_F7, "f8": kVK_F8, "f9": kVK_F9, "f10": kVK_F10,
        "f11": kVK_F11, "f12": kVK_F12, "f13": kVK_F13, "f14": kVK_F14, "f15": kVK_F15,
        "f16": kVK_F16, "f17": kVK_F17, "f18": kVK_F18, "f19": kVK_F19, "f20": kVK_F20
    ]

    private static let characterKeys: [String: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E,
        "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J,
        "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O,
        "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
        "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y,
        "z": kVK_ANSI_Z,
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
        "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9
    ]

    /// Parses one accelerator from `keybindings.json`. Modifier order and letter case do not
    /// matter. Only function keys, letters and digits are accepted: punctuation depends too much
    /// on the layout, and Return, Space, Tab or Delete could edit or send the user's composer if
    /// ChatGPT did not treat the event as a command.
    init?(accelerator: String) {
        let parts = accelerator
            .split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard let keyName = parts.last else { return nil }

        var flags = CGEventFlags()
        for part in parts.dropLast() {
            guard let flag = Self.modifierFlags[part], !flags.contains(flag) else { return nil }
            flags.insert(flag)
        }

        if let key = Self.functionKeys[keyName] {
            self.init(virtualKey: CGKeyCode(key), flags: flags, layoutCharacter: nil)
        } else if let key = Self.characterKeys[keyName] {
            // A bare or Shift-only character is text, not a command: if ChatGPT had a field
            // focused, posting it would type into the user's message.
            guard !flags.isDisjoint(with: [.maskCommand, .maskControl, .maskAlternate]) else {
                return nil
            }
            self.init(virtualKey: CGKeyCode(key), flags: flags, layoutCharacter: keyName)
        } else {
            return nil
        }
    }

    /// A letter or digit binding names a character, but the posted event names a physical key
    /// position. On a layout where that position produces something else, posting would be a
    /// different shortcut, possibly another ChatGPT command, so a positive mismatch is refused.
    /// When the system reports no character there is no evidence against the standard position.
    func matchesLayout(producedCharacters: String?) -> Bool {
        guard let layoutCharacter,
              let producedCharacters,
              !producedCharacters.isEmpty else {
            return true
        }
        return producedCharacters.lowercased() == layoutCharacter
    }

    /// Finds the one chord this Mac binds to `command`, or explains why none can be trusted.
    ///
    /// Refusing is always safe here: an unavailable binding only means no toggle on this Mac,
    /// never a blocked recording anywhere.
    static func resolve(keybindings data: Data?, command: String) -> ChatGPTVoiceShortcutResolution {
        struct Binding: Decodable {
            let command: String
            let key: String?
        }

        guard let data,
              let bindings = try? JSONDecoder().decode([Binding].self, from: data) else {
            return .missing
        }
        let configured = bindings.filter { $0.command == command }.compactMap { $0.key }
        guard !configured.isEmpty else { return .missing }

        var candidates: [ChatGPTVoiceShortcut] = []
        for accelerator in configured {
            if let shortcut = ChatGPTVoiceShortcut(accelerator: accelerator),
               !candidates.contains(shortcut) {
                candidates.append(shortcut)
            }
        }

        let chosen: ChatGPTVoiceShortcut
        if candidates.contains(.acceptedLocal) {
            // A Mac that already works locally posts the identical event as a recipient.
            chosen = .acceptedLocal
        } else if candidates.count == 1, let only = candidates.first {
            chosen = only
        } else {
            // Which of several chords ChatGPT honours is not knowable from this file.
            return .unsupported
        }

        // One event must mean one command. A chord also bound elsewhere could run that command
        // instead of, or as well as, the microphone toggle.
        let isShared = bindings.contains { binding in
            guard binding.command != command, let key = binding.key else { return false }
            return ChatGPTVoiceShortcut(accelerator: key) == chosen
        }
        return isShared ? .unsupported : .resolved(chosen)
    }
}
