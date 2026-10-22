import SwiftData
import SwiftUI

/// History retries are file-only retranscriptions, not a replay of an old paste
/// destination. Both header and player share ownership so expanding an entry or
/// clicking its other Retry control cannot start a second request for that WAV.
@MainActor
final class HistoryAudioRetryState: ObservableObject {
    static let shared = HistoryAudioRetryState()
    @Published private(set) var activeIDs: Set<UUID> = []

    func begin(_ id: UUID) -> Bool {
        guard !activeIDs.contains(id) else { return false }
        activeIDs.insert(id)
        return true
    }

    func finish(_ id: UUID) { activeIDs.remove(id) }

    static func audioURL(for transcription: Transcription) -> URL? {
        guard let source = transcription.audioFileURL, let url = URL(string: source),
              url.isFileURL, FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
}

struct HistoryAudioRetryButton: View {
    let transcription: Transcription
    var actionOverride: (() -> Void)? = nil
    @ObservedObject private var retryState = HistoryAudioRetryState.shared
    @EnvironmentObject private var engine: VoiceInkEngine
    @Environment(\.modelContext) private var modelContext

    private var isRunning: Bool { retryState.activeIDs.contains(transcription.id) }

    var body: some View {
        Button(action: retry) {
            Group {
                if isRunning {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                }
            }
            .frame(width: 28, height: 28)
            .background(RoundedRectangle(cornerRadius: AppTheme.Radius.control)
                .fill(AppTheme.Surface.window.opacity(0.92)))
        }
        .buttonStyle(.plain)
        .disabled(isRunning || HistoryAudioRetryState.audioURL(for: transcription) == nil)
        .accessibilityLabel("Retry")
        .accessibilityIdentifier("history-retry-\(transcription.id)")
        .help(HistoryAudioRetryState.audioURL(for: transcription) == nil
              ? "No saved audio to retry" : "Retry transcription")
    }

    private func retry() {
        if let actionOverride { actionOverride(); return }
        guard let url = HistoryAudioRetryState.audioURL(for: transcription) else { return }
        // Match the existing player's selected/current Mode. Freeze it now;
        // switching apps or Modes during this request must not reinterpret it.
        guard let mode = ModeManager.shared.resolvedEnabledConfiguration(preferredId: nil) else {
            NotificationManager.shared.showNotification(title: String(localized: "No mode selected"), type: .error)
            return
        }
        guard let configuration = ModeRuntimeResolver.transcriptionConfiguration(
            mode: mode, transcriptionModelManager: engine.transcriptionModelManager
        ) else {
            NotificationManager.shared.showNotification(title: String(localized: "No transcription model selected"), type: .error)
            return
        }
        guard retryState.begin(transcription.id) else { return }
        let service = AudioTranscriptionService(modelContext: modelContext, engine: engine)
        Task {
            defer { retryState.finish(transcription.id) }
            do {
                _ = try await service.retranscribeAudio(from: url, using: configuration.model, mode: mode)
                NotificationManager.shared.showNotification(title: String(localized: "Retranscription successful"), type: .success)
            } catch {
                NotificationManager.shared.showNotification(title: error.localizedDescription, type: .error,
                    copyText: transcription.historyDisplayText)
            }
        }
    }
}
