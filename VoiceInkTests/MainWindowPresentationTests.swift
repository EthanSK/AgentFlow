import AppKit
import SwiftUI
import Testing
@testable import VoiceInkPlusPlus

@Suite(.serialized)
struct MainWindowPresentationTests {
    @Test func mainAppDefaultIsFourZoomStepsWithoutChangingRecorderScale() {
        #expect(MainWindowLayout.defaultZoom == 1.20)
        #expect(MainWindowLayout.minimumSize == CGSize(width: 1140, height: 876))
        #expect(RecorderHUDScaleStore.defaultScale == 0.85)
    }

    @MainActor @Test func collapsedHistoryCopyWorksAtEnlargedSizeWithoutExpanding() throws {
        let canonical = "Opening words\n<app_selection source=\"test\">"
            + String(repeating: "Do not lose any of this full context. ", count: 1000)
            + "</app_selection>\nFinal words"
        let styled = LiveSelectionStyledMath.coloredXML(canonical, color: LiveSelectionStyledMath.selectionColor)
        let rows = [
            Transcription(text: canonical, duration: 0, enhancedText: "Short enhanced preview"),
            Transcription(text: "", duration: 0, realtimeDraftText: canonical,
                          transcriptionStatus: .recoveredAfterInterruption),
            Transcription(text: styled, duration: 0)
        ]
        let pasteboard = NSPasteboard.general
        let savedItems = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        defer {
            pasteboard.clearContents()
            let restored = savedItems.map { values in
                let item = NSPasteboardItem()
                values.forEach { item.setData($0.1, forType: $0.0) }
                return item
            }
            pasteboard.writeObjects(restored)
        }
        for row in rows {
            var expanded = 0
            var checked = 0
            let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 100, y: 100),
                size: MainWindowLayout.minimumSize), styleMask: [.titled, .resizable],
                backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView:
                HistoryCardRow(transcription: row, isExpanded: false, isChecked: false,
                    onToggleExpand: { expanded += 1 }, onToggleCheck: { checked += 1 },
                    onShowInfo: {})
                    .frame(width: MainWindowLayout.logicalWidth,
                           height: MainWindowLayout.logicalMinimumHeight, alignment: .topLeading)
                    .modifier(MainWindowZoom())
            )
            window.contentView = host
            window.orderFrontRegardless()
            window.makeKey()
            defer { window.orderOut(nil); window.close() }
            settle(host)
            #expect(host.frame.size == MainWindowLayout.minimumSize)
            #expect(host.bounds.size == host.frame.size)

            // Real mouse events at the scaled Copy control, not its action or
            // AXPress. It must work before expansion, including a recovered draft.
            try click(window, identifier: "history-copy-\(row.id)")
            #expect(pasteboard.string(forType: .string) == canonical)
            #expect(expanded == 0 && checked == 0)
            let savedSource = row.historyDisplayText
            try click(window, identifier: "history-copy-\(row.id)-latex")
            #expect(pasteboard.string(forType: .string) ==
                HistoryContextPresentation.copyText(savedSource, format: .latex))
            #expect(pasteboard.string(forType: .string)?.contains("\\textsf") == true)
            #expect(expanded == 0 && checked == 0)
            #expect(row.historyDisplayText == savedSource)

            let preview = try accessibilityFrame(window, identifier: "history-preview-\(row.id)")
            let copy = try accessibilityFrame(window, identifier: "history-copy-\(row.id)-latex")
            #expect(preview.width >= MainWindowLayout.minimumSize.width - 2)
            #expect(preview.maxY <= copy.minY)

            // Optional native fixture artifact for a visual check, using only
            // synthetic test content and never a user's saved History.
            if row.text == styled,
               let path = ProcessInfo.processInfo.environment["VIPP_TEST_HISTORY_COPY_SNAPSHOT"],
               let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: path))
            }

            // The independent entry opener still receives clicks under zoom.
            try click(window, logicalPoint: NSPoint(x: 300, y: 20))
            #expect(expanded == 1 && checked == 0)
        }

        var selected = 0, checked = 0
        let row = Transcription(text: styled, duration: 0)
        try withWindow(TranscriptionListItem(transcription: row, isSelected: false, isChecked: false,
            onSelect: { selected += 1 }, onToggleCheck: { checked += 1 })) { window in
            try click(window, identifier: "history-list-copy-\(row.id)")
            #expect(pasteboard.string(forType: .string) == canonical)
            try click(window, identifier: "history-list-copy-\(row.id)-latex")
            #expect(pasteboard.string(forType: .string) == styled)
            #expect(selected == 0 && checked == 0)
            let preview = try accessibilityFrame(window, identifier: "history-list-preview-\(row.id)")
            let copy = try accessibilityFrame(window, identifier: "history-list-copy-\(row.id)-latex")
            #expect(preview.width >= MainWindowLayout.minimumSize.width - 24 - 2)
            #expect(preview.maxY <= copy.minY)
        }
    }

    @MainActor @Test func historyRetryIsTopLevelAndDoesNotExpandOrCheckTheRow() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try Data([0]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let row = Transcription(text: "Transcription Failed", duration: 0,
                                audioFileURL: url.absoluteString, transcriptionStatus: .failed)
        var retries = 0, expanded = 0, checked = 0
        try withWindow(HistoryCardRow(transcription: row, isExpanded: false, isChecked: false,
            onToggleExpand: { expanded += 1 }, onToggleCheck: { checked += 1 },
            onShowInfo: {}, onRetry: { retries += 1 })) { window in
            try click(window, identifier: "history-retry-\(row.id)")
            #expect(retries == 1 && expanded == 0 && checked == 0)
        }
    }

    @MainActor @Test func historyRetryRejectsMissingAudioAndDuplicateInFlightRequests() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        let row = Transcription(text: "Retained draft", duration: 0, audioFileURL: url.absoluteString)
        var retries = 0
        try withWindow(HistoryAudioRetryButton(transcription: row, actionOverride: { retries += 1 })) { window in
            try click(window, logicalPoint: NSPoint(x: 14, y: 14))
            #expect(retries == 0)
        }
        try Data([0]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let state = HistoryAudioRetryState.shared
        #expect(state.begin(row.id))
        #expect(!state.begin(row.id))
        defer { state.finish(row.id) }
        try withWindow(HistoryAudioRetryButton(transcription: row, actionOverride: { retries += 1 })) { window in
            try click(window, logicalPoint: NSPoint(x: 14, y: 14))
            #expect(retries == 0)
        }
        state.finish(row.id)
        #expect(state.begin(row.id))
        state.finish(row.id)
        #expect(row.text == "Retained draft")
    }

    @MainActor @Test func historyRetryBlocksCooperativeQuitUntilItFinishes() {
        let state = HistoryAudioRetryState.shared
        let id = UUID()
        #expect(state.begin(id))
        defer { state.finish(id) }
        #expect(AppDelegate.shouldBlockTermination(hasInFlightSessions: false,
            hasHistoryRetries: !state.activeIDs.isEmpty))
        state.finish(id)
        #expect(!AppDelegate.shouldBlockTermination(hasInFlightSessions: false,
            hasHistoryRetries: !state.activeIDs.isEmpty))
        #expect(AppDelegate.shouldBlockTermination(hasInFlightSessions: true, hasHistoryRetries: false))
    }

    @MainActor @Test func exitDraftAndRecoveredCodexCopyStayAtTheTopAndPreserveCompleteXML() throws {
        let xml = "<speech start_at=\"123\" end_at=\"456\">\n"
            + String(repeating: "Every retained word and attribute. ", count: 1000)
            + "\n</speech>\n<local_screenshot path=\"/private/test.png\"/>"
        let pasteboard = NSPasteboard.general
        let savedItems = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        defer {
            pasteboard.clearContents()
            pasteboard.writeObjects(savedItems.map { values in
                let item = NSPasteboardItem()
                values.forEach { item.setData($0.1, forType: $0.0) }
                return item
            })
        }
        try withWindow(HistoryDraftHeader(title: "Live draft at exit", text: xml,
                                          copyIdentifier: "test-draft-copy")) { window in
            try click(window, identifier: "test-draft-copy")
            #expect(pasteboard.string(forType: .string) == xml)
            try click(window, identifier: "test-draft-copy-latex")
            #expect(pasteboard.string(forType: .string) ==
                HistoryContextPresentation.copyText(xml, format: .latex))
        }
        pasteboard.clearContents()
        try withWindow(HistoryRecoveredCodexView(text: xml)) { window in
            try click(window, identifier: "history-recovered-codex-copy")
            #expect(pasteboard.string(forType: .string) == xml)
            try click(window, identifier: "history-recovered-codex-copy-latex")
            #expect(pasteboard.string(forType: .string) ==
                HistoryContextPresentation.copyText(xml, format: .latex))
        }
    }

    @MainActor private func withWindow<Content: View>(_ content: Content,
        action: (NSWindow) throws -> Void) rethrows {
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 100, y: 100),
            size: MainWindowLayout.minimumSize), styleMask: [.titled, .resizable],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: content
            .frame(width: MainWindowLayout.logicalWidth, height: MainWindowLayout.logicalMinimumHeight,
                   alignment: .topLeading)
            .modifier(MainWindowZoom()))
        window.contentView = host
        window.orderFrontRegardless()
        window.makeKey()
        defer { window.orderOut(nil); window.close() }
        settle(host)
        try action(window)
    }

    @MainActor private func settle(_ host: NSView) {
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        host.layoutSubtreeIfNeeded()
    }

    @MainActor private func click(_ window: NSWindow, logicalPoint: NSPoint) throws {
        let scale = MainWindowLayout.defaultZoom
        let point = NSPoint(x: logicalPoint.x * scale,
                            y: MainWindowLayout.minimumSize.height - logicalPoint.y * scale)
        try click(window, windowPoint: point)
    }

    // Query only our hosted synthetic fixture. Resolve actual native geometry,
    // so a longer localized label cannot silently move the test's click target.
    @MainActor private func accessibilityFrame(_ window: NSWindow, identifier: String) throws -> NSRect {
        var seen = Set<ObjectIdentifier>()
        func find(_ object: NSObject) -> NSObject? {
            guard seen.insert(ObjectIdentifier(object)).inserted else { return nil }
            if object.responds(to: NSSelectorFromString("accessibilityIdentifier")),
               object.value(forKey: "accessibilityIdentifier") as? String == identifier { return object }
            if object.responds(to: NSSelectorFromString("accessibilityChildren")),
               let children = object.value(forKey: "accessibilityChildren") as? [NSObject] {
                for child in children { if let match = find(child) { return match } }
            }
            return nil
        }
        let node = try #require(find(window), "Missing fixture control: \(identifier)")
        let value = try #require(node.value(forKey: "accessibilityFrame") as? NSValue)
        return value.rectValue
    }

    @MainActor private func click(_ window: NSWindow, identifier: String) throws {
        let frame = try accessibilityFrame(window, identifier: identifier)
        #expect(frame.width > 0 && frame.height > 0)
        let point = window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
        try click(window, windowPoint: point)
    }

    @MainActor private func click(_ window: NSWindow, windowPoint point: NSPoint) throws {
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: point,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
        }
        let up = try event(.leftMouseUp)
        NSApp.postEvent(up, atStart: false)
        NSApp.sendEvent(try event(.leftMouseDown))
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        NSApp.sendEvent(up)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
}
