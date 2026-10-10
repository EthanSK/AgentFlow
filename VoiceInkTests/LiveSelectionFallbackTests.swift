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
        var rangeBounds: CGRect?
        var markerBounds: CGRect?
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

    func selection(of element: Int, source: LiveSelectionTextSource) -> LiveSelectionSnapshot? {
        selectionReads.append(element)
        guard let node = nodes[element] else { return nil }
        let text: String?
        let bounds: CGRect?
        switch source {
        case .selectedText: text = node.selectedText; bounds = node.bounds
        case .selectedRange: text = node.rangeText; bounds = node.rangeBounds ?? node.bounds
        case .textMarkers: text = node.markerText; bounds = node.markerBounds ?? node.bounds
        }
        return text.map { LiveSelectionSnapshot(text: $0, bounds: bounds) }
    }

    func isSame(_ lhs: Int, _ rhs: Int) -> Bool { lhs == rhs }
}

struct LiveSelectionFallbackTests {
    @Test func provenAncestorBeatsNearerBoundlessPointerFragment() {
        let probe = FakeSelectionProbe()
        let g = gesture(CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 100))
        probe.hitTargets = [(g.mouseDown, 1)]
        probe.nodes[1] = .init(role: "AXStaticText", parent: 2, selectedText: "symbol")
        probe.nodes[2] = .init(role: "AXWebArea", markerText: "full symbol selection",
            markerBounds: CGRect(x: 90, y: 90, width: 160, height: 30))
        #expect(resolve(probe, g).candidate?.text == "full symbol selection")
        probe.nodes[2]?.markerBounds = CGRect(x: 700, y: 700, width: 100, height: 30)
        #expect(resolve(probe, g).candidate?.text == "symbol")
        #expect(LiveSelectionAccessibilityResolver(probe: probe, gesture: g,
            gestureInSourceWindow: true, requiresGestureBounds: true).resolve().candidate == nil)
    }

    @Test func budgetExpiryKeepsNearestPointerFallback() {
        let probe = FakeSelectionProbe()
        let g = gesture(CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 100))
        probe.hitTargets = [(g.mouseDown, 1)]
        probe.nodes[1] = .init(role: "AXStaticText", parent: 2, selectedText: "chosen text")
        probe.nodes[2] = .init(role: "AXWebArea", selectedText: "must not read")
        probe.expireAfterRoleReads = 2
        #expect(resolve(probe, g).candidate?.text == "chosen text")
        #expect(!probe.selectionReads.contains(2))
    }

    @Test func containingMarkerWithTheSameBoundsDoesNotWidenTheSelection() {
        let probe = FakeSelectionProbe()
        probe.focused = 1
        let bounds = CGRect(x: 90, y: 90, width: 130, height: 30)
        var g = gesture(CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 100))
        g.callbackLagMilliseconds = 0
        #expect(g.spanEvidence(for: bounds, in: display) == .consistent)
        probe.nodes[1] = .init(role: "AXStaticText", selectedText: "α + β", rangeText: "α + β",
            markerText: "  before α + β after\n", bounds: bounds, markerBounds: bounds)
        #expect(resolve(probe, g).candidate?.text == "α + β")
        #expect(resolve(probe, g).candidate?.source == .selectedText)
        #expect(resolve(probe, g).preventedWidening == 1)
        probe.nodes[1]?.role = "AXTextArea"
        #expect(resolve(probe, g).candidate?.text == "α + β")
        probe.nodes[1]?.role = "AXStaticText"
        probe.nodes[1]?.markerText = "longer unrelated selection"
        #expect(resolve(probe, g).candidate?.text == "α + β")
        probe.nodes[1]?.markerText = "before α + β after"
        probe.nodes[1]?.markerBounds = CGRect(x: 700, y: 700, width: 100, height: 30)
        #expect(resolve(probe, g).candidate?.text == "α + β")
        probe.nodes[1]?.markerBounds = nil
        probe.nodes[1]?.bounds = nil
        probe.nodes[1]?.rangeBounds = bounds
        #expect(resolve(probe, g).candidate?.text == "α + β")
    }

    @Test func aggregateGeometryIsDiagnosticNotAGlyphSelectionVeto() {
        for text in ["t: ethaneus99@gmail.com‾ or ethaneustg@gmail.com‾?",
                     "Which support account should I select: ethaneus99@gmail.com‾ or ethaneustg@gmail.com‾?"] {
            for (role, clicks) in [("AXStaticText", 0), ("AXStaticText", 1),
                                   ("AXWebArea", 0), ("AXWebArea", 1),
                                   ("AXTextArea", 0), ("AXTextArea", 1)] {
                let probe = FakeSelectionProbe()
                probe.focused = 1
                probe.nodes[1] = .init(role: role, markerText: text,
                    markerBounds: CGRect(x: 80, y: 100, width: 678, height: 22))
                var g = gesture(CGPoint(x: 402, y: 110), CGPoint(x: 558, y: 110))
                g.callbackLagMilliseconds = 6
                g.clickCount = clicks
                let result = precisionResolve(probe, g)
                // With no competing exact selection, do not guess a glyph cut
                // or discard the host's only reported range based on its box.
                #expect(result.candidate?.text == text)
                #expect(result.observedOverextended == 1)
            }
        }
    }

    @Test func narrowerAddressRangeBeatsBroadMarkerInEitherDragDirection() {
        let selected = "  ethaneus99@gmail.com‾\n"
        for points in [(402.0, 558.0), (558.0, 402.0)] {
            let probe = FakeSelectionProbe()
            probe.focused = 1
            probe.nodes[1] = .init(role: "AXStaticText", rangeText: selected,
                markerText: "before \(selected) or ethaneustg@gmail.com‾?",
                rangeBounds: CGRect(x: 400, y: 100, width: 160, height: 22),
                markerBounds: CGRect(x: 80, y: 100, width: 678, height: 22))
            var g = gesture(CGPoint(x: points.0, y: 110), CGPoint(x: points.1, y: 110))
            g.callbackLagMilliseconds = 6
            let result = precisionResolve(probe, g)
            #expect(result.candidate?.text == selected)
            #expect(result.candidate?.source == .selectedRange)
            #expect(result.candidate?.spanEvidence == .consistent)
            #expect(result.observedOverextended == 1)
        }
    }

    @Test func genuineCrossElementMarkerStillWinsWhenTheLeafMissesADragEndpoint() {
        for points in [(382.0, 756.0), (756.0, 382.0)] {
            let probe = FakeSelectionProbe()
            probe.focused = 1
            probe.nodes[1] = .init(role: "AXStaticText", selectedText: "α + β",
                markerText: "  before α + β after\n",
                bounds: CGRect(x: 380, y: 100, width: 180, height: 22),
                markerBounds: CGRect(x: 380, y: 100, width: 378, height: 22))
            var g = gesture(CGPoint(x: points.0, y: 110), CGPoint(x: points.1, y: 110))
            g.callbackLagMilliseconds = 6
            let result = precisionResolve(probe, g)
            #expect(result.candidate?.text == "  before α + β after\n")
            #expect(result.candidate?.source == .textMarkers)
            #expect(result.acceptedMarkerExpansion == 1)
        }
    }

    @Test func broadFocusedParagraphDoesNotHideTheNarrowPointerRange() {
        let probe = FakeSelectionProbe()
        probe.focused = 1
        probe.nodes[1] = .init(role: "AXWebArea", markerText: "whole question",
            markerBounds: CGRect(x: 80, y: 100, width: 678, height: 22))
        probe.nodes[2] = .init(role: "AXStaticText", rangeText: "first address",
            rangeBounds: CGRect(x: 400, y: 100, width: 160, height: 22))
        var g = gesture(CGPoint(x: 402, y: 110), CGPoint(x: 558, y: 110))
        g.callbackLagMilliseconds = 6
        probe.hitTargets = [(g.mouseDown, 2)]
        let result = precisionResolve(probe, g)
        #expect(result.candidate?.text == "first address")
        #expect(result.candidate?.tier == .pointerElement)
        #expect(result.observedOverextended == 1)
    }

    @Test func matchingTokenlessTextIsNotDiscardedByAnAggregateBox() {
        let probe = FakeSelectionProbe()
        probe.focused = 1
        probe.nodes[1] = .init(role: "AXStaticText", selectedText: "whole question",
            markerText: "whole question", markerBounds: CGRect(x: 80, y: 100, width: 678, height: 22))
        var g = gesture(CGPoint(x: 402, y: 110), CGPoint(x: 558, y: 110))
        g.callbackLagMilliseconds = 6
        #expect(precisionResolve(probe, g).candidate?.text == "whole question")
    }

    @Test func multiclickAndLaggedGesturesNeverInventGlyphEndpointsOrWidenText() {
        for (clicks, lag) in [(2, 0), (3, 0), (1, 51)] {
            let probe = FakeSelectionProbe()
            probe.focused = 1
            probe.nodes[1] = .init(role: "AXStaticText", markerText: "whole paragraph",
                markerBounds: CGRect(x: 80, y: 100, width: 678, height: 22))
            var g = gesture(CGPoint(x: 402, y: 110), CGPoint(x: 558, y: 110))
            g.clickCount = clicks
            g.callbackLagMilliseconds = lag
            #expect(precisionResolve(probe, g).candidate?.text == "whole paragraph")
            #expect(precisionResolve(probe, g).candidate?.spanEvidence == .unverifiable)
            probe.nodes[1]?.rangeText = "paragraph"
            probe.nodes[1]?.rangeBounds = CGRect(x: 400, y: 100, width: 160, height: 22)
            #expect(precisionResolve(probe, g).candidate?.text == "paragraph")
            #expect(precisionResolve(probe, g).preventedWidening == 1)
        }
    }

    @Test func multilineSpanChecksRowsButPreservesAutoscrollAndEditableRanges() {
        var g = gesture(CGPoint(x: 402, y: 110), CGPoint(x: 100, y: 170))
        g.callbackLagMilliseconds = 0
        let probe = FakeSelectionProbe()
        probe.focused = 1
        probe.nodes[1] = .init(role: "AXStaticText", markerText: "two lines\n",
            markerBounds: CGRect(x: 80, y: 100, width: 678, height: 82))
        #expect(precisionResolve(probe, g).candidate?.text == "two lines\n")
        probe.nodes[1]?.markerBounds = CGRect(x: 80, y: 100, width: 678, height: 160)
        #expect(precisionResolve(probe, g).candidate?.text == "two lines\n")
        #expect(precisionResolve(probe, g).candidate?.spanEvidence == .overextended)
        probe.nodes[1]?.markerBounds = CGRect(x: 80, y: -20, width: 678, height: 280)
        #expect(precisionResolve(probe, g).candidate?.spanEvidence == .unverifiable)
        probe.nodes[1] = .init(role: "AXTextArea", rangeText: "ordinary editor range",
            rangeBounds: CGRect(x: 80, y: 100, width: 678, height: 160))
        #expect(precisionResolve(probe, g).candidate?.text == "ordinary editor range")
    }

    @Test func spanDiagnosticsNeverReplaceTheSourceSelection() {
        let probe = FakeSelectionProbe()
        probe.focused = 1
        probe.nodes[1] = .init(role: "AXStaticText", markerText: "host selection",
            markerBounds: CGRect(x: 80, y: 100, width: 678, height: 22))
        var g = gesture(CGPoint(x: 402, y: 110), CGPoint(x: 558, y: 110))
        g.callbackLagMilliseconds = 0
        #expect(resolve(probe, g).candidate?.text == "host selection")
        #expect(precisionResolve(probe, g).candidate?.text == "host selection")
        #expect(precisionResolve(probe, g).observedOverextended == 1)
        g.callbackLagMilliseconds = nil
        #expect(precisionResolve(probe, g).candidate?.spanEvidence == .unverifiable)
        #expect(precisionResolve(probe, nil).candidate?.text == "host selection")
    }

    private func precisionResolve(_ probe: FakeSelectionProbe, _ gesture: LiveSelectionGesture?) -> LiveSelectionResolution {
        LiveSelectionAccessibilityResolver(probe: probe, gesture: gesture, gestureInSourceWindow: true,
            checksDragSpan: true, sourceWindowBounds: display).resolve()
    }

    @Test func partialWordPointerTextBeatsAContainingFocusedMarkerEvenWithLag() {
        for lag in [6, 68] {
            for points in [(402.0, 426.0), (426.0, 402.0)] {
                let probe = FakeSelectionProbe()
                probe.focused = 1
                probe.nodes[1] = .init(role: "AXWebArea", markerText: "I'll keep new coverage small",
                    markerBounds: CGRect(x: 80, y: 100, width: 678, height: 22))
                probe.nodes[2] = .init(role: "AXStaticText", parent: 1, selectedText: "ll keep")
                var g = gesture(CGPoint(x: points.0, y: 110), CGPoint(x: points.1, y: 110))
                g.callbackLagMilliseconds = lag
                g.clickCount = 0
                probe.hitTargets = [(g.mouseDown, 2)]
                let result = precisionResolve(probe, g)
                #expect(result.candidate?.text == "ll keep")
                #expect(result.candidate?.tier == .pointerElement)
                #expect(result.candidate?.source == .selectedText)
                #expect(probe.hitTests == [g.mouseDown])
            }
        }
    }

    @Test func pointerTokenlessSelectionDoesNotLoseToItsOwnContainingMarker() {
        let probe = FakeSelectionProbe()
        probe.nodes[2] = .init(role: "AXStaticText", selectedText: "sym", markerText: "symbol boundary",
            markerBounds: CGRect(x: 380, y: 100, width: 170, height: 22))
        var g = gesture(CGPoint(x: 402, y: 110), CGPoint(x: 426, y: 110))
        g.callbackLagMilliseconds = 5
        probe.hitTargets = [(g.mouseDown, 2)]
        let result = precisionResolve(probe, g)
        #expect(result.candidate?.text == "sym")
        #expect(result.preventedWidening == 1)
        // Never carry a boundless foreground fallback into a background read.
        let background = LiveSelectionAccessibilityResolver(probe: probe, gesture: g,
            gestureInSourceWindow: true, requiresGestureBounds: true, checksDragSpan: true).resolve()
        #expect(background.candidate?.text == "symbol boundary")
    }

    @Test func unrelatedPointerTextAndFocusedEditorsKeepTheirExistingSafety() {
        let probe = FakeSelectionProbe()
        probe.focused = 1
        probe.nodes[1] = .init(role: "AXTextArea", rangeText: "editor selection",
            rangeBounds: CGRect(x: 400, y: 100, width: 80, height: 22))
        probe.nodes[2] = .init(role: "AXStaticText", selectedText: "other")
        let g = gesture(CGPoint(x: 402, y: 110), CGPoint(x: 426, y: 110))
        probe.hitTargets = [(g.mouseDown, 2)]
        #expect(precisionResolve(probe, g).candidate?.text == "editor selection")
        #expect(probe.hitTests.isEmpty)
    }

    @Test func degenerateFarMathGeometryIsCountedAndStillRejected() {
        let probe = FakeSelectionProbe()
        probe.focused = 1
        probe.nodes[1] = .init(role: "AXMathElement", markerText: "far math",
            markerBounds: CGRect(x: 700, y: 700, width: 1, height: 1))
        let result = resolve(probe, gesture(CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 100)))
        #expect(result.candidate == nil)
        #expect(result.degenerateBounds == 1)
        #expect(result.rejectedElsewhere == 1)
    }

    @Test func sourceIdentityIgnoresTransientOverlayButStillRejectsResizedWindow() {
        let window = LiveSelectionWindow(ownerPID: 42, bounds: CGRect(x: 0, y: 0, width: 500, height: 500),
            alpha: 1, windowID: 99)
        let overlay = LiveSelectionWindow(ownerPID: 42, bounds: CGRect(x: 90, y: 90, width: 200, height: 100),
            alpha: 1, windowID: 100, layer: 101)
        let g = gesture(CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 100))
        let identity = LiveSelectionReadIdentity(processIdentifier: 42, gesture: g, windows: [overlay, window])
        #expect(identity.window?.windowID == 99)
        #expect(identity.isValid(frontmostPID: 7, windows: [window]))
        let resized = LiveSelectionWindow(ownerPID: 42, bounds: CGRect(x: 0, y: 0, width: 600, height: 500),
            alpha: 1, windowID: 99)
        #expect(!identity.isValid(frontmostPID: 42, windows: [resized]))
        #expect(g.touchesWindow(ownedBy: 42, in: [overlay]) == false)
        let floating = LiveSelectionWindow(ownerPID: 42, bounds: window.bounds,
            alpha: 1, windowID: 101, layer: 3)
        let floatingIdentity = LiveSelectionReadIdentity(processIdentifier: 42, gesture: g,
            windows: [overlay, floating])
        #expect(floatingIdentity.window?.windowID == 101)
        #expect(floatingIdentity.isValid(frontmostPID: 7, windows: [floating]))
        #expect(g.touchesWindow(ownedBy: 42, in: [floating]) == true)
        // CGWindow inventory is front-to-back: a real floating panel above a
        // same-app main window owns this gesture, not the window underneath it.
        let overlapping = LiveSelectionReadIdentity(processIdentifier: 42, gesture: g,
            windows: [overlay, floating, window])
        #expect(overlapping.window?.windowID == 101)
        #expect(!overlapping.isValid(frontmostPID: 42, windows: [window]))
        #expect(overlapping.isValid(frontmostPID: 7, windows: [floating, window]))
    }

    @Test func cachedSpeechAnchorsPreserveUnicodeRevisionsAndCopies() throws {
        let original = try #require(LiveSelectionReference("selected words"))
        #expect(original.spokenWordCount == 0)
        let prefix = "  First\tsecond\nthird\u{00a0}fourth\u{2003}👩🏽‍💻  "
        let anchored = original.anchored(after: prefix)
        #expect(anchored.spokenWordCount == 5)
        #expect(anchored.timed(at: Date()).identifiedForCapture(UUID()).spokenWordCount == 5)
        #expect(anchored.scopedToApplication(name: "ChatGPT", bundleID: "com.openai.codex").spokenWordCount == 5)
        #expect(anchored.anchored(after: "revised").spokenWordCount == 1)
        #expect(anchored.anchored(after: "\n\t").spokenWordCount == 0)
        #expect(anchored != original.anchored(after: "different five words right here"))
        let refs = [original.anchored(after: "one two"), original.anchored(after: "one"),
                    original.anchored(after: "one two three four five six")]
        #expect(LiveSelectionReference.previewParts(refs, with: "one two three four") == [
            .speech("one two"), .selection(original.preview), .selection(original.preview),
            .speech("three four"), .selection(original.preview)
        ])
    }

    @Test func longTimelineAnchorReadsAvoidRescanningCumulativeSpeech() throws {
        let original = try #require(LiveSelectionReference("selection"))
        let prefixes = (1...100).map { String(repeating: "spoken word ", count: $0 * 10) }
        let refs = prefixes.map { original.anchored(after: $0) }
        let cachedStart = Date()
        var cached = 0
        for _ in 0..<100 { cached += refs.reduce(0) { $0 + $1.spokenWordCount } }
        let cachedTime = Date().timeIntervalSince(cachedStart)
        let uncachedStart = Date()
        var uncached = 0
        for _ in 0..<100 { uncached += prefixes.reduce(0) { $0 + $1.split(whereSeparator: \.isWhitespace).count } }
        let uncachedTime = Date().timeIntervalSince(uncachedStart)
        #expect(cached == uncached && cached == 10_100_000)
        print("HUD anchor benchmark: cached=\(cachedTime)s uncached=\(uncachedTime)s sameWords=\(cached)")
    }

    @Test func staleAccessorDoesNotMaskFreshMarkerSelectionOnTheSameElement() {
        let probe = FakeSelectionProbe()
        probe.focused = 1
        probe.nodes[1] = .init(role: "AXWebArea", selectedText: "old chat", rangeText: "old range",
            markerText: "new chat highlight", bounds: CGRect(x: 700, y: 700, width: 50, height: 20),
            markerBounds: CGRect(x: 90, y: 90, width: 160, height: 30))
        let result = resolve(probe, gesture(CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 100)))
        #expect(result.candidate?.text == "new chat highlight")
        #expect(result.candidate?.source == .textMarkers)
        #expect(result.candidate?.evidence == .atGesture)
        #expect(result.rejectedElsewhere == 2)
    }

    @Test func provenRangeWinsOverBoundlessSelectedTextWithoutWeakeningBackgroundGuard() {
        let probe = FakeSelectionProbe()
        probe.focused = 1
        probe.nodes[1] = .init(role: "AXWebArea", selectedText: "unproven", rangeText: "proven",
            rangeBounds: CGRect(x: 90, y: 90, width: 160, height: 30))
        let g = gesture(CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 100))
        #expect(resolve(probe, g).candidate?.text == "proven")
        #expect(LiveSelectionAccessibilityResolver(probe: probe, gesture: g, gestureInSourceWindow: true,
            requiresGestureBounds: true).resolve().candidate?.text == "proven")
        probe.nodes[1]?.rangeBounds = nil
        #expect(LiveSelectionAccessibilityResolver(probe: probe, gesture: g, gestureInSourceWindow: true,
            requiresGestureBounds: true).resolve().candidate == nil)
    }

    @Test func allStaleAccessorsRemainRejected() {
        let probe = FakeSelectionProbe()
        probe.focused = 1
        probe.nodes[1] = .init(role: "AXWebArea", selectedText: "old", rangeText: "old", markerText: "old",
            bounds: CGRect(x: 700, y: 700, width: 50, height: 20))
        let result = resolve(probe, gesture(CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 100)))
        #expect(result.candidate == nil)
        #expect(result.rejectedElsewhere == 3)
    }

    @Test func backgroundSelectionRequiresTheSameVisibleWindowAndRangeBounds() {
        let window = LiveSelectionWindow(ownerPID: 42, bounds: CGRect(x: 0, y: 0, width: 500, height: 500), alpha: 1, windowID: 99)
        let g = gesture(CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 100))
        let identity = LiveSelectionReadIdentity(processIdentifier: 42, gesture: g, windows: [window])
        #expect(identity.isValid(frontmostPID: 7, windows: [window]))
        #expect(!identity.isValid(frontmostPID: 42, windows: []))
        let replaced = LiveSelectionWindow(ownerPID: 7, bounds: window.bounds, alpha: 1, windowID: 99)
        #expect(!identity.isValid(frontmostPID: 7, windows: [replaced]))
        let noWindow = LiveSelectionReadIdentity(processIdentifier: 42, gesture: g, windows: [])
        #expect(!noWindow.isValid(frontmostPID: 7, windows: []))
        let probe = FakeSelectionProbe()
        probe.focused = 1
        probe.nodes[1] = .init(role: "AXTextArea", selectedText: "unproven old selection")
        #expect(LiveSelectionAccessibilityResolver(probe: probe, gesture: g, gestureInSourceWindow: true,
            requiresGestureBounds: true).resolve().candidate == nil)
        probe.nodes[1]?.bounds = CGRect(x: 90, y: 90, width: 130, height: 30)
        #expect(LiveSelectionAccessibilityResolver(probe: probe, gesture: g, gestureInSourceWindow: true,
            requiresGestureBounds: true).resolve().candidate?.text == "unproven old selection")
    }
    @Test func codexSelectionRetryBudgetIsBoundedAndAppScoped() {
        let ordinary = LiveSelectionReadPolicy.accessibilityRetryDelays
        #expect(ordinary == [0, 150_000_000])
        #expect(LiveSelectionReadPolicy.accessibilityRetryDelays(for: "com.openai.codex")
                == [0, 150_000_000, 350_000_000, 700_000_000])
        for bundle in ["com.google.Chrome", "com.microsoft.VSCode", "org.telegram.desktop"] {
            #expect(LiveSelectionReadPolicy.accessibilityRetryDelays(for: bundle) == ordinary)
        }
        #expect(LiveSelectionReadPolicy.accessibilityRetryDelays(for: nil) == ordinary)
    }

    private let display = CGRect(x: 0, y: 0, width: 1440, height: 900)

    @Test func missingHitTestsAndUnprovenBackgroundSelectionsAreCountedWithoutText() {
        let probe = FakeSelectionProbe()
        probe.focused = 1
        probe.nodes[1] = .init(role: "AXTextArea", selectedText: "unrelated text")
        let result = LiveSelectionAccessibilityResolver(probe: probe,
            gesture: gesture(CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 100)),
            gestureInSourceWindow: true, requiresGestureBounds: true).resolve()
        #expect(result.candidate == nil)
        #expect(result.hasGesture)
        #expect(result.emptyHitTests == 2)
        #expect(result.rejectedUnverifiable == 1)
        #expect(!resolve(probe, nil).hasGesture)
    }

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

    @Test func browserSelectionFramingPreservesSourceWhitespace() throws {
        let source = "\n  selected code\n\tlast line  \n"
        let data = try JSONSerialization.data(withJSONObject: ["text": source])
        let framed = try #require(String(data: data, encoding: .utf8)) + "\n"
        #expect(LiveSelectionBrowserScriptReader.parseSelectionResult(framed) == source)
        #expect(LiveSelectionBrowserScriptReader.parseSelectionResult(#"{"text":"  \n"}"#) == nil)
        #expect(LiveSelectionBrowserScriptReader.parseSelectionResult("unframed") == nil)
        #expect(ChromeSelectionContextReader.parse(
            #"{"selectedText":"  code\n","url":"https://example.com"}"#
        )?.selectedText == "  code\n")
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
