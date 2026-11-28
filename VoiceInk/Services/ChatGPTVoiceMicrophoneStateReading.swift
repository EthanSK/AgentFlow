// Reads Voice state for Ethan's state-preserving recording hold. The 28 November
// request supersedes the old blind-toggle default; an explicit opt-out stays unknown.
// — GPT-6.1 Sol
import Foundation

enum ChatGPTVoiceMicrophoneStateReading {
    static let preferenceKey = "VIPPVoiceMicrophoneStateReadsEnabled"

    /// Bounded reads default ON; they never enable the previously fragile exposure write. — GPT-6.1 Sol
    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: preferenceKey) == nil || defaults.bool(forKey: preferenceKey)
    }

    // Keep the unsupported exposure experiment dormant. Reading existing labels
    // is separate from requesting a different Accessibility tree. — GPT-6.1 Sol
    static let automaticExposureEnabled = false
}
