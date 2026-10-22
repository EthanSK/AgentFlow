import AppKit
import SwiftUI
import Testing
@testable import VoiceInkPlusPlus

@Suite(.serialized)
struct MainWindowPresentationTests {
    @Test func mainAppDefaultIsActualSizeWithoutChangingRecorderScale() {
        #expect(MainWindowLayout.defaultZoom == 1)
        #expect(MainWindowLayout.minimumSize == CGSize(width: 950, height: 730))
        #expect(RecorderHUDScaleStore.defaultScale == 0.85)
    }

    @MainActor @Test func mainWindowZoomPersistsClampsAndResetsIndependently() throws {
        let suite = "MainWindowZoomTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(0.8, forKey: "RecorderHUDScale")
        let store = MainWindowZoomStore(defaults: defaults)
        #expect(store.scale == 1)
        store.apply(.zoomIn)
        #expect(store.percentage == 110)
        #expect(MainWindowZoomStore(defaults: defaults).scale == 1.1)
        store.apply(.zoomOut)
        #expect(store.scale == 1)
        store.setScale(100)
        #expect(store.scale == 1.5 && !store.canZoomIn)
        store.setScale(-1)
        #expect(store.scale == 0.75 && !store.canZoomOut)
        store.apply(.actualSize)
        #expect(store.scale == 1)
        store.setScale(.nan)
        #expect(store.scale == 1)
        #expect(defaults.double(forKey: "RecorderHUDScale") == 0.8)
        #expect(MainWindowLayout.minimumSize(at: 0.8) == CGSize(width: 760, height: 584))
    }

    @MainActor @Test func mainWindowZoomShortcutsRequireMainWindowAndCommand() throws {
        func event(_ text: String, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: 24))
        }
        for text in ["+", "="] {
            #expect(MainWindowZoomAction.from(try event(text, .command), mainWindowIsKey: true) == .zoomIn)
            #expect(MainWindowZoomAction.from(try event(text, [.command, .shift]), mainWindowIsKey: true) == .zoomIn)
        }
        #expect(MainWindowZoomAction.from(try event("-", .command), mainWindowIsKey: true) == .zoomOut)
        #expect(MainWindowZoomAction.from(try event("0", .command), mainWindowIsKey: true) == .actualSize)
        for flags: NSEvent.ModifierFlags in [[], .shift, .option, [.command, .option], [.command, .control]] {
            #expect(MainWindowZoomAction.from(try event("=", flags), mainWindowIsKey: true) == nil)
        }
        #expect(MainWindowZoomAction.from(try event("=", .command), mainWindowIsKey: false) == nil)
    }

    @MainActor @Test func mainWindowZoomPreservesClickTargetsAtSmallAndLargeScales() throws {
        let suite = "MainWindowZoomClicks-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MainWindowZoomStore(defaults: defaults)
        for scale in [0.75, 1.0, 1.2, 1.5] {
            store.setScale(scale)
            var clicks = 0
            let size = MainWindowLayout.minimumSize(at: scale)
            let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 100, y: 100), size: size),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView:
                Button("Zoom test") { clicks += 1 }
                    .frame(width: 160, height: 40)
                    .position(x: 200, y: 80)
                    .frame(width: MainWindowLayout.logicalWidth,
                           height: MainWindowLayout.logicalMinimumHeight, alignment: .topLeading)
                    .modifier(MainWindowZoom(store: store)))
            window.contentView = host
            window.orderFrontRegardless()
            window.makeKey()
            defer { window.orderOut(nil); window.close() }
            settle(host)
            #expect(host.bounds.size == host.frame.size)
            try click(window, windowPoint: NSPoint(x: 200 * scale,
                y: (MainWindowLayout.logicalMinimumHeight - 80) * scale))
            #expect(clicks == 1)
        }
    }

    @MainActor @Test func mainWindowZoomResizesAfterSwiftUILayoutUpdates() throws {
        let suite = "MainWindowZoomResize-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MainWindowZoomStore(defaults: defaults)
        let manager = WindowManager(zoomStore: store)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 100, y: 100),
            size: MainWindowLayout.minimumSize), styleMask: [.titled, .resizable],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: Color.gray.modifier(MainWindowZoom(store: store)))
        window.contentView = host
        manager.registerMainWindow(window)
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.close() }
        settle(host)
        for scale in [1.2, 0.8, 1.0] {
            store.setScale(scale)
            settle(host)
            #expect(abs(window.contentRect(forFrameRect: window.frame).width - 950 * scale) < 1)
            #expect(abs(host.frame.width - 950 * scale) < 1)
            #expect(host.bounds.size == host.frame.size)
        }
    }

    @MainActor @Test func collapsedHistoryCopyWorksAtEnlargedSizeWithoutExpanding() throws {
        let canonical = "Opening words\n<app_selection source=\"test\"><text>"
            + String(repeating: "Do not lose any of this full context. ", count: 1000)
            + "</text></app_selection>\nFinal words"
        let styled = LiveSelectionStyledMath.coloredXML(canonical, color: LiveSelectionStyledMath.selectionColor)
        let rows = [
            Transcription(text: canonical, duration: 0, enhancedText: "Short enhanced preview"),
            Transcription(text: "Opening words\n\nFinal words", duration: 0, realtimeDraftText: canonical,
                          transcriptionStatus: .completed),
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

            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let path = FileManager.default.temporaryDirectory
                    .appendingPathComponent("AgentFlow-HistoryHeader-fixture.png")
                try bitmap.representation(using: .png, properties: [:])?
                    .write(to: path)
                print("History header fixture: \(path.path)")
            }

            // Real mouse events at the scaled Copy control, not its action or
            // AXPress. It must work before expansion, including a recovered draft.
            try click(window, logicalPoint: NSPoint(x: 730, y: 14))
            #expect(pasteboard.string(forType: .string) == "Opening words\n\nFinal words")
            #expect(expanded == 0 && checked == 0)
            let savedSource = row.historyDisplayText
            try click(window, logicalPoint: NSPoint(x: 850, y: 14))
            #expect(pasteboard.string(forType: .string) ==
                HistoryContextPresentation.message(for: row).text)
            #expect(pasteboard.string(forType: .string) == canonical)
            #expect(expanded == 0 && checked == 0)
            #expect(row.historyDisplayText == savedSource)

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
            try click(window, logicalPoint: NSPoint(x: 892, y: 24))
            #expect(pasteboard.string(forType: .string) == "Opening words\n\nFinal words")
            try click(window, logicalPoint: NSPoint(x: 926, y: 24))
            #expect(pasteboard.string(forType: .string) == canonical)
            #expect(selected == 0 && checked == 0)
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
            try click(window, logicalPoint: NSPoint(x: 690, y: 14))
            #expect(retries == 1 && expanded == 0 && checked == 0)
        }
    }

    @MainActor @Test func expandedHistoryShowsTheFlowMessageAndOnlyRawWordsBelow() throws {
        let xml = "<speech start_at=\"123\" end_at=\"456\">\n\nMy complete request.\n\n</speech>\n"
            + "<app_selection source=\"Example\"><text>Selected context stays here.</text></app_selection>"
        let row = Transcription(text: "My complete request.", duration: 0,
            realtimeDraftText: xml, transcriptionStatus: .completed)
        let before = row.realtimeDraftText
        for expanded in [false, true] {
            try withWindow(HistoryCardRow(transcription: row, isExpanded: expanded, isChecked: false,
                onToggleExpand: {}, onToggleCheck: {}, onShowInfo: {})) { window in
                let host = try #require(window.contentView)
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let path = FileManager.default.temporaryDirectory.appendingPathComponent(
                    "AgentFlow-447-History-\(expanded ? "expanded" : "collapsed").png")
                try #require(bitmap.representation(using: .png, properties: [:])).write(to: path)
                print("Flow History fixture: \(path.path)")
            }
        }
        #expect(row.text == "My complete request." && row.realtimeDraftText == before)
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
            try click(window, logicalPoint: NSPoint(x: 750, y: 14))
            #expect(pasteboard.string(forType: .string) == String(repeating: "Every retained word and attribute. ", count: 1000))
            try click(window, logicalPoint: NSPoint(x: 870, y: 14))
            #expect(pasteboard.string(forType: .string) ==
                HistoryContextPresentation.copyText(xml, format: .formatted))
        }
        pasteboard.clearContents()
        try withWindow(HistoryRecoveredCodexView(text: xml)) { window in
            try click(window, logicalPoint: NSPoint(x: 750, y: 14))
            #expect(pasteboard.string(forType: .string) == String(repeating: "Every retained word and attribute. ", count: 1000))
            try click(window, logicalPoint: NSPoint(x: 870, y: 14))
            #expect(pasteboard.string(forType: .string) ==
                HistoryContextPresentation.copyText(xml, format: .formatted))
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
