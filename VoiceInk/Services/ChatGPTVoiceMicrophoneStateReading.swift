// Keeps the optional Codex microphone UI reader dormant until Ethan explicitly
// enables it. Normal recording uses paired shortcuts and reads no mute controls.
// — GPT-6.1 Sol
import Foundation

enum ChatGPTVoiceMicrophoneStateReading {
    static let preferenceKey = "VIPPVoiceMicrophoneStateReadsEnabled"

    /// Missing preferences deliberately mean OFF; enabling is an explicit future decision. — GPT-6.1 Sol
    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: preferenceKey)
    }
}
