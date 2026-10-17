import SwiftUI

struct TranscriptionListItem: View {
    let transcription: Transcription
    let isSelected: Bool
    let isChecked: Bool
    let onSelect: () -> Void
    let onToggleCheck: () -> Void

    private var message: HistoryContextPresentation.Message {
        HistoryContextPresentation.message(for: transcription)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Toggle("", isOn: Binding(
                    get: { isChecked },
                    set: { _ in onToggleCheck() }
                ))
                .toggleStyle(CircularCheckboxStyle())
                .labelsHidden()

                Text(transcription.timestamp, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Spacer()
                if transcription.duration > 0 {
                    Text(transcription.duration.formatTiming())
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(AppTheme.Surface.card)
                        )
                        .foregroundColor(.secondary)
                }
                HistoryAudioRetryButton(transcription: transcription)
                HistoryCopyButtons(text: message.text,
                                   identifier: "history-list-copy-\(transcription.id)", showsFormattingTitle: false,
                                   rawText: message.rawText)
            }
            // Match the card layout: only metadata/actions share the top row.
            Text(HistoryContextPresentation.listPreview(message.text))
                .font(.system(size: 12, weight: .regular))
                .lineLimit(2)
                .foregroundColor(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("history-list-preview-\(transcription.id)")
        }
        .padding(10)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: AppTheme.Radius.card, style: .continuous)
                    .fill(AppTheme.Selection.fill)
                    .overlay {
                        RoundedRectangle(cornerRadius: AppTheme.Radius.card, style: .continuous)
                            .strokeBorder(AppTheme.Selection.border, lineWidth: 1)
                    }
            } else {
                RoundedRectangle(cornerRadius: AppTheme.Radius.card, style: .continuous)
                    .fill(AppTheme.Surface.subtle)
                    .overlay {
                        RoundedRectangle(cornerRadius: AppTheme.Radius.card, style: .continuous)
                            .strokeBorder(AppTheme.Border.tint, lineWidth: 1)
                    }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
    }
}

struct CircularCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(action: {
            configuration.isOn.toggle()
        }) {
            Image(systemName: configuration.isOn ? "checkmark.circle.fill" : "circle")
                .symbolRenderingMode(.hierarchical)
                .foregroundColor(configuration.isOn ? AppTheme.Selection.foreground : .secondary)
                .font(.system(size: 18))
        }
        .buttonStyle(.plain)
    }
}
