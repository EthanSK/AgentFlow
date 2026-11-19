import AppKit
import SwiftUI
import Testing
@testable import VoiceInkPlusPlus

struct RecorderChatBannerTests {
    @MainActor @Test func recordingAndTranscribingShowTheWholeChatTitle() async throws {
        let title = "💻 Laptop speed and background tasks"
        let target = CodexRecordingTarget(id: UUID(), name: title, executable: URL(fileURLWithPath: "/unused"))
        let mode = ModeConfig(name: "Codex", isAIEnhancementEnabled: false, autoSendKey: .enter)
        let session = RecordingSession()
        session.bindCodexCapture(.init(mode: mode, lookup: Task { target }))
        while session.codexRoute == .detecting { await Task.yield() }
        let recorder = Recorder()
        let assistant = AssistantSession()

        func recordCard(_ text: String, width: CGFloat, narrow: Bool, filename: String) throws {
            let layout = RecorderChatBannerLayout(text, availableWidth: width)
            #expect(layout.separateRow == narrow)
            #expect(layout.cardWidth <= width)
            let label = NSHostingView(rootView: RecorderChatBanner(layout: layout))
            #expect(label.fittingSize.height <= layout.height - (narrow ? MiniRecorderLayoutMetrics.controlBarHeight : 0))
            let card = MiniRecorderView(stateProvider: session, liveTranscriptHeight: 0,
                liveTranscriptWidth: width, recorder: recorder, assistantSession: assistant,
                onRecordButtonTapped: {}, onCloseTapped: {}, onCancelTapped: {}, onAssistantFollowUp: { _ in })
                .frame(width: layout.cardWidth, height: layout.height)
            try attach(card, filename: filename)
        }

        let recording = try #require(session.codexBanner)
        #expect(recording == "Chat detected · " + title)
        try recordCard(recording, width: 1100, narrow: false, filename: "recording")
        try recordCard(recording, width: 390, narrow: true, filename: "narrow-recording")

        session.phase = .transcribing
        session.liveRecordingState = .transcribing
        session.pasteTarget = .init(destination: .primaryCurrentInput, focusedInput: nil)
        let waiting = try #require(session.codexBanner)
        #expect(waiting == "Will send to " + title)
        try recordCard(waiting, width: 1100, narrow: false, filename: "transcribing")
        try attach(TranscribingChip(session: session, style: .mini, availableWidth: 320, onCancel: {}),
                   filename: "stacked-transcription")
        let chip = RecorderChatBannerLayout(waiting, availableWidth: 320, placement: .chip)
        #expect(chip.height > MiniRecorderLayoutMetrics.controlBarHeight)
        #expect(chip.cardWidth <= 320)
        let short = RecorderChatBannerLayout("Will send to A", availableWidth: 1100)
        #expect(short.height == MiniRecorderLayoutMetrics.controlBarHeight)
        #expect(short.cardWidth < RecorderChatBannerLayout(waiting, availableWidth: 1100).cardWidth)
    }

    @MainActor private func attach<V: View>(_ view: V, filename: String) throws {
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        #expect(size.width > 0 && size.height > 0)
        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: size),
                            styleMask: .borderless, backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        panel.contentView = host
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        #if compiler(>=6.2)
        Attachment.record(Array(png), named: filename + ".png")
        #endif
    }
}
