import ApplicationServices
import CoreGraphics
import Foundation
import Testing
@testable import VoiceInkPlusPlus

/// Deterministic stand-in for one source app's Accessibility tree. It records
/// every selection read so tests can prove what was never touched.
private final class FakeSelectionProbe: LiveSelectionAccessibilityProbe {
    struct Node {
        var role: String? = "AXGroup"
        var subrole: String?
        var parent: Int?
        var selectedText: String?
        var rangeText: String?
        var markerText: String?
        var bounds: CGRect?
    }

    var nodes: [Int: Node] = [:]
    var focused: Int?
    var hitTargets: [(point: CGPoint, element: Int)] = []
    var expireAfterRoleReads: Int?
    private(set) var selectionReads: [Int] = []
    private(set) var roleReads = 0
    private(set) var hitTests: [CGPoint] = []

    var isExpired: Bool {
        guard let expireAfterRoleReads else { return false }
        return roleReads >= expireAfterRoleReads
    }

    func focusedElement() -> Int? { focused }

    func element(at point: CGPoint) -> Int? {
        hitTests.append(point)
        return hitTargets.first(where: { $0.point == point })?.element
    }

    func parent(of element: Int) -> Int? { nodes[element]?.parent }

    func role(of element: Int) -> String? {
        roleReads += 1
        return nodes[element]?.role
    }

    func subrole(of element: Int) -> String? { nodes[element]?.subrole }

    func selectedText(of element: Int) -> String? {
        selectionReads.append(element)
        return nodes[element]?.selectedText
    }

    func selectedRangeText(of element: Int) -> String? {
        selectionReads.append(element)
        return nodes[element]?.rangeText
    }

    func selectedMarkerText(of element: Int) -> String? {
        selectionReads.append(element)
        return nodes[element]?.markerText
    }

    func selectionBounds(of element: Int, source: LiveSelectionTextSource) -> CGRect? {
        nodes[element]?.bounds
    }

    func isSame(_ lhs: Int, _ rhs: Int) -> Bool { lhs == rhs }
}

struct LiveSelectionFallbackTests {
    private let display = CGRect(x: 0, y: 0, width: 1440, height: 900)

    private func gesture(_ down: CGPoint, _ up: CGPoint) -> LiveSelectionGesture {
        LiveSelectionGesture(mouseDown: down, mouseUp: up, displays: [display])
    }

    private func resolve(
        _ probe: FakeSelectionProbe,
        _ gesture: LiveSelectionGesture?,
        inSourceWindow: Bool? = true
    ) -> LiveSelectionResolution {
        LiveSelectionAccessibilityResolver(
            probe: probe, gesture: gesture, gestureInSourceWindow: inSourceWindow
        ).resolve()
    }

    @Test func focusedSelectionAtTheGestureNeedsNoPointerWalk() {
        let probe = FakeSelectionProbe()
        probe.nodes[1] = .init(
            role: "AXTextArea", selectedText: "chosen words",
            bounds: CGRect(x: 100, y: 100, width: 200, height: 20)
        )
        probe.focused = 1

        let resolution = resolve(probe, gesture(CGPoint(x: 110, y: 110), CGPoint(x: 290, y: 112)))
        #expect(resolution.candidate == LiveSelectionCandidate(
            text: "chosen words", tier: .focusedElement,
            source: .selectedText, evidence: .atGesture
        ))
        #expect(probe.hitTests.isEmpty)
    }

    @Test func staleFocusedSelectionYieldsToThePointerWebSelection() {
        // Codex-like layout: the composer keeps an old selection while the
        // user highlights non-editable transcript text elsewhere in the page.
        let probe = FakeSelectionProbe()
        probe.nodes[1] = .init(
            role: "AXTextArea", selectedText: "old composer text",
            bounds: CGRect(x: 100, y: 800, width: 300, height: 20)
        )
        probe.nodes[10] = .init(role: "AXStaticText", parent: 11)
        probe.nodes[11] = .init(role: "AXGroup", parent: 12)
        probe.nodes[12] = .init(
            role: "AXWebArea", parent: 13, markerText: "fresh transcript passage",
            bounds: CGRect(x: 100, y: 200, width: 400, height: 40)
        )
        probe.nodes[13] = .init(role: kAXWindowRole)
        probe.focused = 1
        let down = CGPoint(x: 105, y: 205)
        probe.hitTargets = [(down, 10)]

        let resolution = resolve(probe, gesture(down, CGPoint(x: 480, y: 235)))
        #expect(resolution.candidate == LiveSelectionCandidate(
            text: "fresh transcript passage", tier: .pointerElement,
            source: .textMarkers, evidence: .atGesture
        ))
        #expect(resolution.rejectedElsewhere == 1)
        #expect(probe.hitTests.first == down)
    }

    @Test func selectionOnlyElsewhereFailsClosedInsteadOfRepeatingIt() {
        // A window or scroll-bar drag must not re-emit an older highlight.
        let probe = FakeSelectionProbe()
        probe.nodes[1] = .init(
            role: "AXTextArea", selectedText: "earlier highlight",
            bounds: CGRect(x: 600, y: 600, width: 300, height: 20)
        )
        probe.nodes[20] = .init(role: "AXButton", parent: 21)
        probe.nodes[21] = .init(role: kAXWindowRole)
        probe.focused = 1
        let down = CGPoint(x: 50, y: 10)
        probe.hitTargets = [(down, 20)]

        let resolution = resolve(probe, gesture(down, CGPoint(x: 400, y: 12)))
        #expect(resolution.candidate == nil)
        #expect(resolution.rejectedElsewhere == 1)
    }

    @Test func passwordFieldsAreNeverRead() {
        let point = CGPoint(x: 120, y: 120)
        let bounds = CGRect(x: 100, y: 110, width: 200, height: 20)
        let probe = FakeSelectionProbe()
        probe.nodes[1] = .init(
            role: kAXTextFieldRole, subrole: kAXSecureTextFieldSubrole, parent: 2,
            selectedText: "hunter2", bounds: bounds
        )
        probe.nodes[2] = .init(role: "AXGroup", parent: 3, selectedText: "hunter2")
        probe.nodes[3] = .init(role: kAXWindowRole)
        probe.focused = 1
        probe.hitTargets = [(point, 1)]

        let resolution = resolve(probe, gesture(point, point))
        #expect(resolution.candidate == nil)
        #expect(resolution.refusedSecure == 1)
        #expect(!probe.selectionReads.contains(1))
        #expect(!probe.selectionReads.contains(2))

        let roleOnly = FakeSelectionProbe()
        roleOnly.nodes[1] = .init(
            role: kAXSecureTextFieldSubrole, selectedText: "hunter2", bounds: bounds
        )
        roleOnly.focused = 1
        #expect(resolve(roleOnly, gesture(point, point)).candidate == nil)
        #expect(roleOnly.selectionReads.isEmpty)
    }

    @Test func boundlessSelectionMustNotContradictTheSourceWindow() {
        let cases: [(inSourceWindow: Bool?, expected: String?)] = [
            (true, "terminal output"), (nil, "terminal output"), (false, nil)
        ]
        for (inSourceWindow, expected) in cases {
            let probe = FakeSelectionProbe()
            probe.nodes[1] = .init(role: "AXTextArea", selectedText: "terminal output")
            probe.focused = 1
            let point = CGPoint(x: 200, y: 200)
            let resolution = resolve(probe, gesture(point, point), inSourceWindow: inSourceWindow)
            #expect(resolution.candidate?.text == expected)
            if let candidate = resolution.candidate {
                #expect(candidate.evidence == .unverifiable)
            } else {
                #expect(resolution.rejectedOutsideSourceWindow == 1)
            }
        }
    }

    @Test func nearestSelectionToThePointerWinsOverABoundlessFocusedField() {
        let point = CGPoint(x: 300, y: 300)
        let pointerNearer = FakeSelectionProbe()
        pointerNearer.nodes[1] = .init(role: "AXTextArea", selectedText: "composer draft")
        pointerNearer.nodes[10] = .init(role: "AXGroup", parent: 11)
        pointerNearer.nodes[11] = .init(role: "AXTextArea", parent: 12, selectedText: "nearest")
        pointerNearer.nodes[12] = .init(role: kAXWindowRole)
        pointerNearer.focused = 1
        pointerNearer.hitTargets = [(point, 10)]
        #expect(resolve(pointerNearer, gesture(point, point)).candidate == LiveSelectionCandidate(
            text: "nearest", tier: .pointerElement, source: .selectedText, evidence: .unverifiable
        ))

        // When the gesture lands inside the focused field, that field is the
        // nearest selection owner; outer ancestors are not read at all.
        let insideFocused = FakeSelectionProbe()
        insideFocused.nodes[1] = .init(role: "AXTextArea", parent: 2, selectedText: "composer draft")
        insideFocused.nodes[2] = .init(
            role: "AXWebArea", markerText: "outer",
            bounds: CGRect(x: 250, y: 250, width: 100, height: 100)
        )
        insideFocused.nodes[30] = .init(role: "AXStaticText", parent: 1)
        insideFocused.focused = 1
        insideFocused.hitTargets = [(point, 30)]
        #expect(resolve(insideFocused, gesture(point, point)).candidate == LiveSelectionCandidate(
            text: "composer draft", tier: .focusedElement,
            source: .selectedText, evidence: .unverifiable
        ))
        #expect(!insideFocused.selectionReads.contains(2))
    }

    @Test func selectedRangeIsReadBeforeTextMarkers() {
        let probe = FakeSelectionProbe()
        probe.nodes[1] = .init(
            role: "AXTextArea", selectedText: "  \n ", rangeText: "range words",
            markerText: "marker words"
        )
        probe.focused = 1
        let point = CGPoint(x: 10, y: 10)
        #expect(resolve(probe, gesture(point, point)).candidate?.source == .selectedRange)
        #expect(resolve(probe, gesture(point, point)).candidate?.text == "range words")
    }

    @Test func pointerWalkIsBoundedAndStopsAtWindowChrome() {
        let point = CGPoint(x: 400, y: 400)
        let deep = FakeSelectionProbe()
        for index in 0..<100 {
            deep.nodes[index] = .init(role: "AXGroup", parent: index + 1)
        }
        deep.nodes[100] = .init(role: "AXWebArea", markerText: "too far away")
        deep.hitTargets = [(point, 0)]
        let deepResolution = resolve(deep, gesture(point, point))
        #expect(deepResolution.candidate == nil)
        #expect(deepResolution.examinedElements == LiveSelectionReadPolicy.maximumAncestorDepth)

        let windowed = FakeSelectionProbe()
        windowed.nodes[0] = .init(role: "AXGroup", parent: 1)
        windowed.nodes[1] = .init(role: kAXWindowRole, parent: 2)
        windowed.nodes[2] = .init(
            role: "AXGroup", selectedText: "beyond the window",
            bounds: CGRect(x: 390, y: 390, width: 20, height: 20)
        )
        windowed.hitTargets = [(point, 0)]
        let windowResolution = resolve(windowed, gesture(point, point))
        #expect(windowResolution.candidate == nil)
        #expect(windowResolution.examinedElements == 1)
        #expect(!windowed.selectionReads.contains(2))
    }

    @Test func exhaustedBudgetStopsFurtherReads() {
        let point = CGPoint(x: 400, y: 400)
        let probe = FakeSelectionProbe()
        for index in 0..<5 {
            probe.nodes[index] = .init(role: "AXGroup", parent: index + 1)
        }
        probe.nodes[5] = .init(
            role: "AXTextArea", selectedText: "reachable only with more time",
            bounds: CGRect(x: 390, y: 390, width: 20, height: 20)
        )
        probe.hitTargets = [(point, 0)]
        probe.expireAfterRoleReads = 2

        let resolution = resolve(probe, gesture(point, point))
        #expect(resolution.candidate == nil)
        #expect(resolution.examinedElements == 2)
        #expect(!probe.selectionReads.contains(5))
    }

    @Test func cocoaGestureConvertsToAccessibilityCoordinatesAcrossDisplays() throws {
        let primary = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let secondary = CGRect(x: 1440, y: 200, width: 1920, height: 1080)
        let converted = try #require(LiveSelectionGesture.fromCocoa(
            mouseDown: CGPoint(x: 100, y: 800),
            mouseUp: CGPoint(x: 1500, y: 300),
            screenFrames: [primary, secondary]
        ))
        #expect(converted.mouseDown == CGPoint(x: 100, y: 100))
        #expect(converted.mouseUp == CGPoint(x: 1500, y: 600))
        #expect(converted.displays == [primary, CGRect(x: 1440, y: -380, width: 1920, height: 1080)])
        #expect(converted.hitTestPoints == [converted.mouseDown, converted.mouseUp])
        #expect(LiveSelectionGesture.fromCocoa(
            mouseDown: .zero, mouseUp: .zero, screenFrames: []
        ) == nil)

        let doubleClick = gesture(CGPoint(x: 50, y: 50), CGPoint(x: 51, y: 50))
        #expect(doubleClick.hitTestPoints == [CGPoint(x: 50, y: 50)])

        #expect(converted.evidence(for: CGRect(x: 90, y: 95, width: 50, height: 16)) == .atGesture)
        #expect(converted.evidence(for: CGRect(x: 120, y: 120, width: 10, height: 10)) == .atGesture)
        #expect(converted.evidence(for: CGRect(x: 700, y: 700, width: 100, height: 20)) == .elsewhere)
        // Missing, zero, off-display, or absurd geometry is "cannot prove",
        // never proof that a selection is stale.
        #expect(converted.evidence(for: nil) == .unverifiable)
        #expect(converted.evidence(for: .zero) == .unverifiable)
        #expect(converted.evidence(for: CGRect(x: -9000, y: -9000, width: 100, height: 20)) == .unverifiable)
        #expect(converted.evidence(for: CGRect(x: 0, y: 0, width: 200_000, height: 20)) == .unverifiable)
    }

    @Test func gestureMustTouchAVisibleSourceWindowWhenTheListIsKnown() {
        let windows = [
            LiveSelectionWindow(ownerPID: 42, bounds: CGRect(x: 0, y: 0, width: 800, height: 600), alpha: 1),
            LiveSelectionWindow(ownerPID: 7, bounds: CGRect(x: 1000, y: 0, width: 400, height: 400), alpha: 1),
            LiveSelectionWindow(ownerPID: 42, bounds: CGRect(x: 1000, y: 500, width: 100, height: 100), alpha: 0)
        ]
        // A drag that starts in the source window and overshoots still counts.
        #expect(gesture(CGPoint(x: 100, y: 100), CGPoint(x: 1200, y: 100))
            .touchesWindow(ownedBy: 42, in: windows) == true)
        let elsewhere = gesture(CGPoint(x: 1100, y: 100), CGPoint(x: 1050, y: 550))
        #expect(elsewhere.touchesWindow(ownedBy: 42, in: windows) == false)
        #expect(elsewhere.touchesWindow(ownedBy: 42, in: []) == nil)
    }

    @Test func browserOverridesStayNarrowReadOnlyAndPasswordSafe() throws {
        #expect(LiveSelectionBrowserScriptReader.engine(for: "com.apple.Safari") == .safari)
        #expect(LiveSelectionBrowserScriptReader.engine(for: "com.microsoft.edgemac") == .chromium)
        // Chrome's richer DOM probe already ran; generic apps never get scripts.
        #expect(LiveSelectionBrowserScriptReader.engine(for: "com.google.Chrome") == nil)
        #expect(LiveSelectionBrowserScriptReader.engine(for: "com.openai.codex") == nil)
        #expect(LiveSelectionBrowserScriptReader.engine(for: nil) == nil)

        let browserWindow = LiveSelectionWindow(
            ownerPID: 42, bounds: CGRect(x: 50, y: 50, width: 400, height: 300), alpha: 1
        )
        #expect(LiveSelectionBrowserScriptReader.mayReadForGesture(
            gesture(CGPoint(x: 100, y: 100), CGPoint(x: 250, y: 110)),
            processIdentifier: 42, windows: [browserWindow]
        ))
        #expect(!LiveSelectionBrowserScriptReader.mayReadForGesture(
            gesture(CGPoint(x: 600, y: 600), CGPoint(x: 700, y: 700)),
            processIdentifier: 42, windows: [browserWindow]
        ))
        #expect(LiveSelectionBrowserScriptReader.mayReadForGesture(
            gesture(CGPoint(x: 600, y: 600), CGPoint(x: 700, y: 700)),
            processIdentifier: 42, windows: []
        ))

        let safari = try #require(LiveSelectionBrowserScriptReader.source(for: "com.apple.Safari"))
        #expect(safari.hasPrefix("if application id \"com.apple.Safari\" is running then\n"))
        #expect(safari.contains("do JavaScript"))
        let edge = try #require(LiveSelectionBrowserScriptReader.source(for: "com.microsoft.edgemac"))
        #expect(edge.hasPrefix("if application id \"com.microsoft.edgemac\" is running then\n"))
        #expect(edge.contains("execute javascript"))

        for javascript in [
            LiveSelectionBrowserScriptReader.selectionJavaScript,
            ChromeSelectionContextReader.selectionJavaScript
        ] {
            #expect(javascript.contains("a.type!=='password'"))
        }
        let chrome = LiveSelectionBrowserScript.chromium(
            bundleID: "com.google.Chrome", javascript: "a\"b\\c"
        )
        #expect(chrome.hasPrefix("if application id \"com.google.Chrome\" is running then\n"))
        #expect(chrome.contains(#"return (execute javascript "a\"b\\c")"#))
    }

    @Test func liveSelectionPathStaysReadOnlyAndClipboardFree() throws {
        let reader = try repositorySource("VoiceInk/Services/LiveSelectionTextReader.swift")
        let capture = try repositorySource("VoiceInk/Services/LiveSelectionCapture.swift")
        for code in [reader, capture] {
            for forbidden in [
                "NSPasteboard", "SelectedTextManager", "menuAction", "KeySender",
                "CGEvent", "AXUIElementSetAttributeValue", "AXUIElementPerformAction",
                "AXManualAccessibility", "AXEnhancedUserInterface", ".activate(",
                "kAXFocusedAttribute", "AXUIElementCreateSystemWide"
            ] {
                #expect(!code.contains(forbidden), "live selection path must not use \(forbidden)")
            }
        }
        #expect(capture.contains("LiveSelectionTextReader.resolveAccessibility"))
        #expect(!capture.contains("SelectedTextService.fetchSelectedText"))
        #expect(reader.contains("AXUIElementCreateApplication(processIdentifier)"))
        #expect(reader.contains("AXUIElementSetMessagingTimeout"))
        // One bounded settle re-read, never an open-ended polling loop.
        #expect(LiveSelectionReadPolicy.accessibilityRetryDelays.count == 2)
        #expect(LiveSelectionReadPolicy.accessibilityRetryDelays.first == 0)
        #expect(Double(LiveSelectionReadPolicy.messagingTimeout)
                < LiveSelectionReadPolicy.accessibilityBudget)
    }

    private func repositorySource(_ relativePath: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
