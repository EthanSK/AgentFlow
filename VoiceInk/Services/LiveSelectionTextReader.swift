import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import os

// MARK: - Live highlighted-text fallback chain
//
// VoiceInk++ turns ordinary highlights made while a recording is live into a
// bounded reading trail for the receiving agent. That trail is only useful if
// it works across many apps, so capture walks an ordered chain of strictly
// read-only mechanisms and stops at the first result it can tie to the user's
// own selection gesture:
//
//   1. App override — Chrome's bounded DOM probe (in LiveSelectionCapture). It
//      runs first only because it also supplies scrubbed page context.
//   2. `focusedElement` — the source app's own focused element. In ordinary
//      editors this is the control that owns the new selection.
//   3. `pointerElement` — an app-scoped hit test at the gesture's endpoints,
//      then a bounded walk to the nearest selection-bearing ancestor. This
//      reaches non-editable text (web pages, chat transcripts, read-only
//      views) whose selection is not owned by the focused control.
//   4. App override — Safari/Edge bounded read-only JavaScript, used only when
//      Accessibility exposed nothing.
//
// Every candidate element is read through three public-API shapes in order:
// `AXSelectedText`; `AXSelectedTextRange` plus `AXStringForRange`; and the
// WebKit/Chromium text-marker selection (`AXSelectedTextMarkerRange` plus
// `AXStringForTextMarkerRange`), the same read-only attributes VoiceOver uses
// for web content.
//
// Hard boundaries (FAILED_APPROACHES.md, "Clipboard-mutating selected-text
// capture during recording-context setup"):
// - Never copy, synthesize a key or menu command, or touch the pasteboard. An
//   older transcript may own the pasteboard for Primary delivery right now.
// - Never write an Accessibility attribute, perform an action, focus, raise or
//   activate anything, and never flip an app's accessibility switches to make
//   a hidden Electron/Chromium tree appear. Such apps fail closed instead.
// - Never read password fields.
// - Every query is scoped to the stable frontmost source process, limited by a
//   per-message timeout plus a whole-attempt budget, and yields nothing rather
//   than a guess. LiveSelectionReference owns the XML grammar and preserves the
//   full captured text independently of the compact HUD/message preview.

/// Which read-only mechanism produced a live highlight. Diagnostic only: the
/// final `<app_selection>`/`<codex_selection>` grammar deliberately omits it.
enum LiveSelectionTier: String, Equatable, Sendable {
    case chromeDOM
    case vscodeBridge
    case focusedElement
    case pointerElement
    case browserScript
}

enum LiveSelectionTextSource: String, Equatable, Sendable {
    /// `AXSelectedText` on the element.
    case selectedText
    /// `AXSelectedTextRange` resolved through `AXStringForRange`.
    case selectedRange
    /// WebKit/Chromium text-marker selection, which also covers non-editable
    /// page text that no focused control owns.
    case textMarkers
}

/// Whether a selection's on-screen bounds tie it to the gesture just made.
enum LiveSelectionBoundsEvidence: String, Equatable, Sendable {
    /// The selection rect (plus tolerance) contains a gesture endpoint.
    case atGesture
    /// No usable on-screen bounds; the element does not expose them.
    case unverifiable
    /// Valid on-screen bounds far from both endpoints: a stale selection left
    /// in a focused field, or an older web selection after a scroll-bar or
    /// window drag. Never emitted as a fresh highlight.
    case elsewhere
}

/// A consistency filter, not proof of exact glyph-level selection. Chromium may
/// expose a paragraph-wide range when a drag ends inside rendered mathematics.
enum LiveSelectionSpanEvidence: String, Equatable, Sendable {
    case consistent
    case overextended
    case unverifiable
}

enum LiveSelectionReadPolicy {
    /// Chromium/Electron publish a new selection into their Accessibility tree
    /// asynchronously after mouse-up, and may build that tree lazily on the
    /// first read. One bounded re-read catches both without a copy fallback.
    /// The first attempt runs immediately after LiveSelectionCapture's
    /// existing 40 ms settle delay.
    static let accessibilityRetryDelays: [UInt64] = [0, 150_000_000]
    /// A newly foregrounded Electron window may publish its selected range
    /// after both ordinary reads have returned empty. Give the Codex/ChatGPT
    /// host two later chances, including one for a newly loaded chat's tree,
    /// not a poller or a wider Accessibility search.
    /// Every attempt still requires the same frontmost source and is canceled
    /// by a new mouse-down or recording stop. No extra wait follows success.
    static func accessibilityRetryDelays(for bundleID: String?) -> [UInt64] {
        bundleID == "com.openai.codex"
            ? accessibilityRetryDelays + [350_000_000, 700_000_000]
            : accessibilityRetryDelays
    }
    /// Whole-attempt budget across every Accessibility message.
    static let accessibilityBudget: TimeInterval = 0.35
    /// Per-message timeout so one wedged app cannot hold capture for the
    /// system's multi-second default.
    static let messagingTimeout: Float = 0.2
    /// Deep enough for web DOMs, short enough that a window without any
    /// selection-bearing element is abandoned quickly.
    static let maximumAncestorDepth = 32
    /// Selection bounds within this many points of either gesture endpoint
    /// count as the gesture's own selection (drag overshoot, margins).
    static let boundsTolerance: CGFloat = 32
    static let windowTolerance: CGFloat = 2
    static let browserScriptTimeout: TimeInterval = 0.75

    static func isSecure(role: String?, subrole: String?) -> Bool {
        role == kAXSecureTextFieldSubrole || subrole == kAXSecureTextFieldSubrole
    }
}

/// The selection gesture in Accessibility/Quartz global coordinates (origin at
/// the primary display's top-left, y increasing downward).
struct LiveSelectionGesture: Equatable, Sendable {
    let mouseDown: CGPoint
    let mouseUp: CGPoint
    let displays: [CGRect]
    var clickCount = 1
    /// Pointer coordinates are sampled at the callback, not at event creation.
    /// Missing or delayed samples cannot justify clipping/rejecting a range.
    var callbackLagMilliseconds: Int? = nil

    /// NSEvent/NSScreen report Cocoa global coordinates (origin at the primary
    /// display's bottom-left, y up). `screenFrames.first` must be the primary
    /// menu-bar display, which `NSScreen.screens` guarantees.
    static func fromCocoa(
        mouseDown: CGPoint,
        mouseUp: CGPoint,
        screenFrames: [CGRect],
        clickCount: Int = 1,
        callbackLagMilliseconds: Int? = nil
    ) -> Self? {
        guard let primary = screenFrames.first, primary.height > 0 else { return nil }
        let top = primary.maxY
        return Self(
            mouseDown: CGPoint(x: mouseDown.x, y: top - mouseDown.y),
            mouseUp: CGPoint(x: mouseUp.x, y: top - mouseUp.y),
            displays: screenFrames.map {
                CGRect(x: $0.minX, y: top - $0.maxY, width: $0.width, height: $0.height)
            },
            clickCount: clickCount,
            callbackLagMilliseconds: callbackLagMilliseconds
        )
    }

    /// Mouse-down first: a drag's anchor sits inside the text the user chose,
    /// while mouse-up often overshoots onto a neighbouring control.
    var hitTestPoints: [CGPoint] {
        let dx = mouseUp.x - mouseDown.x
        let dy = mouseUp.y - mouseDown.y
        return dx * dx + dy * dy < 16 ? [mouseDown] : [mouseDown, mouseUp]
    }

    func evidence(for bounds: CGRect?) -> LiveSelectionBoundsEvidence {
        guard let raw = bounds, !raw.isNull, !raw.isInfinite else { return .unverifiable }
        let rect = raw.standardized
        // A zero rect, a window-relative/garbage rect that lies on no display,
        // or an absurd size means the app did not report usable geometry. That
        // is "cannot prove", never proof of staleness.
        guard rect.minX.isFinite, rect.minY.isFinite,
              rect.width.isFinite, rect.height.isFinite,
              rect.width > 0 || rect.height > 0,
              rect.width < 100_000, rect.height < 100_000,
              displays.contains(where: { $0.intersects(rect) }) else {
            return .unverifiable
        }
        let zone = rect.insetBy(
            dx: -LiveSelectionReadPolicy.boundsTolerance,
            dy: -LiveSelectionReadPolicy.boundsTolerance
        )
        return zone.contains(mouseDown) || zone.contains(mouseUp) ? .atGesture : .elsewhere
    }

    func coversBothEndpoints(_ bounds: CGRect?) -> Bool {
        guard evidence(for: bounds) == .atGesture, let bounds else { return false }
        let zone = bounds.standardized.insetBy(dx: -LiveSelectionReadPolicy.boundsTolerance,
                                               dy: -LiveSelectionReadPolicy.boundsTolerance)
        return zone.contains(mouseDown) && zone.contains(mouseUp)
    }

    /// Reject only clear over-extension of a fresh single-drag range. Multi-click
    /// word/paragraph selection, delayed callbacks, tiny math rectangles and
    /// autoscroll do not describe glyph endpoints, so remain unverifiable.
    /// The existing 32-point margin absorbs ordinary glyph-edge overshoot. This
    /// never trims text, reconstructs it from pixels, or reads whole documents.
    func spanEvidence(for bounds: CGRect?, in window: CGRect?) -> LiveSelectionSpanEvidence {
        let dx = mouseUp.x - mouseDown.x
        let dy = mouseUp.y - mouseDown.y
        // AppKit's global monitor reports zero clicks for real drags as well as
        // one. Only explicit double/triple-click counts select word/paragraph
        // units; treating zero as unknown disabled this guard on the live host.
        guard (0...1).contains(clickCount), dx * dx + dy * dy >= 16,
              let lag = callbackLagMilliseconds, lag >= 0, lag <= 50,
              let bounds, evidence(for: bounds) != .unverifiable else { return .unverifiable }
        let rect = bounds.standardized
        guard rect.width > 2, rect.height > 2 else { return .unverifiable }
        if let window, !window.insetBy(dx: -LiveSelectionReadPolicy.windowTolerance,
                                      dy: -LiveSelectionReadPolicy.windowTolerance).contains(rect) {
            return .unverifiable
        }
        let slack = LiveSelectionReadPolicy.boundsTolerance
        let minY = min(mouseDown.y, mouseUp.y) - slack
        let maxY = max(mouseDown.y, mouseUp.y) + slack
        guard rect.minY >= minY, rect.maxY <= maxY else { return .overextended }
        // A multiline union rectangle cannot identify the selected columns on
        // its first/last lines. Do not pretend horizontal clipping can do that.
        if abs(dy) <= 8 {
            guard rect.minX >= min(mouseDown.x, mouseUp.x) - slack,
                  rect.maxX <= max(mouseDown.x, mouseUp.x) + slack else { return .overextended }
        }
        return .consistent
    }

    /// Whether either endpoint lies over an on-screen window owned by the
    /// source process. `nil` means the window list was unavailable, so this
    /// check neither proves nor disproves the source.
    func touchesWindow(ownedBy pid: pid_t, in windows: [LiveSelectionWindow]) -> Bool? {
        guard !windows.isEmpty else { return nil }
        return windows.contains { window in
            guard window.ownerPID == pid, window.isContentWindow, window.alpha > 0, !window.bounds.isEmpty else {
                return false
            }
            let zone = window.bounds.insetBy(
                dx: -LiveSelectionReadPolicy.windowTolerance,
                dy: -LiveSelectionReadPolicy.windowTolerance
            )
            return zone.contains(mouseDown) || zone.contains(mouseUp)
        }
    }
}

/// Owner and Quartz bounds of one on-screen window. Neither needs Screen
/// Recording permission; titles and pixels are never read.
struct LiveSelectionWindow: Equatable, Sendable {
    let ownerPID: pid_t
    let bounds: CGRect
    let alpha: Double
    var windowID: CGWindowID? = nil
    var layer: Int = 0

    // Preserve floating/modal content panels (including ChatGPT's floating
    // window); only menu/tooltip-level overlays are excluded as source identity.
    var isContentWindow: Bool { layer < Int(CGWindowLevelForKey(.popUpMenuWindow)) }

    static func onScreen() -> [LiveSelectionWindow] {
        guard let entries = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }
        return entries.compactMap { entry in
            guard let owner = entry[kCGWindowOwnerPID as String] as? Int,
                  let boundsDictionary = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary) else {
                return nil
            }
            return LiveSelectionWindow(
                ownerPID: pid_t(truncatingIfNeeded: owner),
                bounds: bounds,
                alpha: entry[kCGWindowAlpha as String] as? Double ?? 1,
                windowID: (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                layer: entry[kCGWindowLayer as String] as? Int ?? 0
            )
        }
    }
}

/// A read is owned by the selection gesture's source window, not keyboard focus.
/// This is read-only context capture, not a saved paste destination or permission
/// to activate anything. Without a verifiable window, keep the old foreground
/// requirement; background reads additionally require selection-range geometry.
struct LiveSelectionReadIdentity: Sendable {
    let processIdentifier: pid_t
    let window: LiveSelectionWindow?

    init(processIdentifier: pid_t, gesture: LiveSelectionGesture?, windows: [LiveSelectionWindow]) {
        self.processIdentifier = processIdentifier
        let eligible = windows.filter { candidate in
            // Tooltips and selection overlays can disappear during the bounded
            // read. Preserve front-to-back ordering among real content windows:
            // a floating panel above the main window owns its own gesture.
            candidate.ownerPID == processIdentifier && candidate.isContentWindow
                && candidate.windowID != nil && candidate.alpha > 0
                && gesture.map { candidate.bounds.contains($0.mouseUp) } == true
        }
        window = eligible.first
    }

    func isValid(frontmostPID: pid_t?, windows: [LiveSelectionWindow]) -> Bool {
        guard processIdentifier > 0 else { return false }
        guard let window else { return frontmostPID == processIdentifier }
        return windows.contains {
            $0.windowID == window.windowID && $0.ownerPID == processIdentifier
                && $0.isContentWindow && $0.bounds == window.bounds && $0.alpha > 0
        }
    }
}

struct LiveSelectionCandidate: Equatable, Sendable {
    let text: String
    let tier: LiveSelectionTier
    let source: LiveSelectionTextSource
    let evidence: LiveSelectionBoundsEvidence
    var spanEvidence: LiveSelectionSpanEvidence = .unverifiable
}

/// Text and geometry from the same AX selection representation. Mixing an
/// integer range's text with unrelated web-marker bounds can reject a genuine
/// highlight after the host changes chats (or accept an old selection instead).
struct LiveSelectionSnapshot {
    let text: String
    let bounds: CGRect?
}

/// Counts-only outcome for one Accessibility attempt. It never carries the
/// text of a rejected candidate.
struct LiveSelectionResolution: Equatable, Sendable {
    var candidate: LiveSelectionCandidate?
    var accessibilityTrusted = true
    var examinedElements = 0
    var rejectedElsewhere = 0
    var rejectedOutsideSourceWindow = 0
    var refusedSecure = 0
    var emptyHitTests = 0
    var rejectedUnverifiable = 0
    var incompleteMessages = 0
    var missingMarkerRanges = 0
    var unavailableMarkerText = 0
    var degenerateBounds = 0
    var budgetExhausted = false
    var hasGesture = false
    var observedOverextended = 0
    var preventedWidening = 0
    var acceptedMarkerExpansion = 0
}

/// Read-only Accessibility surface for one source process. The live
/// implementation is created from `AXUIElementCreateApplication(sourcePID)`,
/// so every element it returns was vended by the source app itself. That
/// construction is the identity binding: WebKit can vend remote web content
/// from a helper process, so comparing an element's own PID would reject real
/// Safari/WKWebView selections without adding proof.
protocol LiveSelectionAccessibilityProbe {
    associatedtype Element
    var isExpired: Bool { get }
    func focusedElement() -> Element?
    func element(at point: CGPoint) -> Element?
    func parent(of element: Element) -> Element?
    func role(of element: Element) -> String?
    func subrole(of element: Element) -> String?
    func selection(of element: Element, source: LiveSelectionTextSource) -> LiveSelectionSnapshot?
    func isSame(_ lhs: Element, _ rhs: Element) -> Bool
}

/// Pure tier policy over a probe, so ordering, secure-field refusal,
/// stale-selection rejection, and walk bounds are unit-testable without a
/// live app.
struct LiveSelectionAccessibilityResolver<Probe: LiveSelectionAccessibilityProbe> {
    let probe: Probe
    let gesture: LiveSelectionGesture?
    /// `false` only when the window list positively shows that neither gesture
    /// endpoint was over the source app. Bounds-proven candidates do not need
    /// it; bounds-less candidates must not contradict it.
    let gestureInSourceWindow: Bool?
    var requiresGestureBounds = false
    /// Codex's marker rectangles may describe the entire rendered paragraph,
    /// not the highlighted glyphs. Use them as diagnostic evidence and prefer
    /// the pointer's actual selection before an aggregate focused marker.
    var checksDragSpan = false
    var sourceWindowBounds: CGRect? = nil

    func resolve() -> LiveSelectionResolution {
        var resolution = LiveSelectionResolution()
        resolution.hasGesture = gesture != nil
        var visited: [Probe.Element] = []
        var focused: Probe.Element?
        var focusedCandidate: LiveSelectionCandidate?
        var pointerFallback: LiveSelectionCandidate?

        if let element = probe.focusedElement() {
            focused = element
            visited.append(element)
            // A secure editor's parent may expose aggregate text. Stop this
            // attempt before either the field or an ancestor can be queried.
            let focusedRole = probe.role(of: element)
            if LiveSelectionReadPolicy.isSecure(
                role: focusedRole, subrole: probe.subrole(of: element)
            ) {
                resolution.refusedSecure += 1
                return resolution
            }
            if let candidate = read(
                element, role: focusedRole, tier: .focusedElement, into: &resolution
            ) {
                // A nearby Codex marker is not proof of glyph-level selection:
                // the live 414 trace repeatedly returned a whole sentence here
                // before the pointer leaf was examined. Editors and other hosts
                // retain the fast path; Codex markers get the bounded pointer
                // comparison, without focus changes or document-wide reads.
                if candidate.evidence == .atGesture
                    && !(checksDragSpan && candidate.source == .textMarkers && gesture != nil) {
                    resolution.candidate = candidate
                    return resolution
                }
                focusedCandidate = candidate
            }
        }

        if let gesture {
            points: for point in gesture.hitTestPoints {
                guard !probe.isExpired else { break }
                guard var element = probe.element(at: point) else {
                    resolution.emptyHitTests += 1
                    continue
                }
                for _ in 0..<LiveSelectionReadPolicy.maximumAncestorDepth {
                    guard !probe.isExpired else { break points }
                    let role = probe.role(of: element)
                    if LiveSelectionReadPolicy.isSecure(
                        role: role, subrole: probe.subrole(of: element)
                    ) {
                        resolution.refusedSecure += 1
                        break
                    }
                    // Window chrome and the application object never own a text
                    // selection; walking past them would only widen the read.
                    if role == kAXWindowRole || role == kAXApplicationRole { break }
                    if let focused, probe.isSame(element, focused) {
                        // The gesture landed inside the focused element, so its
                        // selection is the nearest one to the pointer.
                        if let focusedCandidate {
                            // Do not walk past an actual focused editor into
                            // unrelated aggregate text. A nearer pointer fallback
                            // still wins within this editor's own boundary.
                            resolution.candidate = pointerFallback ?? focusedCandidate
                            return resolution
                        }
                    } else if !visited.contains(where: { probe.isSame($0, element) }) {
                        visited.append(element)
                        if let candidate = read(
                            element, role: role, tier: .pointerElement, into: &resolution
                        ) {
                            if candidate.evidence == .atGesture {
                                // A foreground pointer leaf's AXSelectedText is
                                // the app's explicit highlight. Do not replace it
                                // with an ancestor marker that merely contains it.
                                // Background capture still requires range geometry.
                                if prefersPointerSelection(pointerFallback, over: candidate) {
                                    resolution.preventedWidening += 1
                                    resolution.candidate = pointerFallback
                                } else {
                                    resolution.candidate = candidate
                                }
                                return resolution
                            }
                            // A boundless leaf fragment must not hide a complete
                            // range proved at this gesture by its parent. Keep the
                            // nearest fallback if bounded walking finds no proof.
                            if pointerFallback == nil { pointerFallback = candidate }
                        }
                    }
                    guard let parent = probe.parent(of: element) else { break }
                    element = parent
                }
            }
        }

        // Bounds-less focused selection: today's baseline behavior, kept only
        // when the pointer found nothing nearer and the gesture was not shown
        // to be outside the source app.
        resolution.candidate = pointerFallback ?? focusedCandidate
        return resolution
    }

    private func read(
        _ element: Probe.Element,
        role: String?,
        tier: LiveSelectionTier,
        into resolution: inout LiveSelectionResolution
    ) -> LiveSelectionCandidate? {
        resolution.examinedElements += 1
        let subrole = role == nil || role == kAXTextFieldRole ? probe.subrole(of: element) : nil
        // Password fields are refused before any selection read, even though
        // macOS normally withholds their contents anyway.
        if LiveSelectionReadPolicy.isSecure(role: role, subrole: subrole) {
            resolution.refusedSecure += 1
            return nil
        }

        var unproven: LiveSelectionCandidate?
        var proven: LiveSelectionCandidate?
        var provenBounds: CGRect?
        // Chromium can expose a leaf-local integer selection and a complete
        // cross-element marker selection on the same non-editable text node.
        // Editors retain their own range; never replace one with aggregate text.
        let mayPreferCompleteMarker = ["AXStaticText", "AXGroup", "AXWebArea", "AXLink",
                                       "AXHeading", "AXMathElement"].contains(role ?? "")
        for source in [LiveSelectionTextSource.selectedText, .selectedRange, .textMarkers] {
            guard !probe.isExpired else { break }
            guard let snapshot = probe.selection(of: element, source: source),
                  let text = Self.meaningful(snapshot.text) else { continue }
            let evidence = gesture?.evidence(for: snapshot.bounds) ?? .unverifiable
            let span = (mayPreferCompleteMarker || source == .textMarkers)
                ? gesture?.spanEvidence(for: snapshot.bounds, in: sourceWindowBounds) ?? .unverifiable
                : .unverifiable
            if checksDragSpan && span == .overextended {
                resolution.observedOverextended += 1
                // Diagnostic only. Build 414's live trace includes repeated
                // overextended-range refusals while highlights were missed.
                // An aggregate rectangle cannot infer the selected glyphs.
                // Keep the existing elsewhere/window/password safety guards.
            }
            if let bounds = snapshot.bounds, !bounds.isNull, !bounds.isInfinite,
               bounds.width >= 0, bounds.height >= 0, bounds.width <= 2, bounds.height <= 2 {
                resolution.degenerateBounds += 1
            }
            switch evidence {
            case .elsewhere:
                resolution.rejectedElsewhere += 1
                // A nonempty stale accessor must not mask a fresh, independently
                // bounded selection exposed by another accessor on this element.
                continue
            case .unverifiable where gestureInSourceWindow == false:
                resolution.rejectedOutsideSourceWindow += 1
            case .unverifiable where requiresGestureBounds:
                resolution.rejectedUnverifiable += 1
            case .atGesture:
                let candidate = LiveSelectionCandidate(text: text, tier: tier, source: source,
                                                       evidence: evidence, spanEvidence: span)
                if source == .textMarkers && prefersPointerSelection(unproven, over: candidate) {
                    resolution.preventedWidening += 1
                    continue
                }
                guard mayPreferCompleteMarker else { return candidate }
                if let first = proven {
                    // Containment alone can turn one highlighted address into a
                    // whole sentence. Expand only when the earlier range misses
                    // a drag endpoint and this independently consistent marker
                    // covers both. Equal/broader boxes are not exactness proof.
                    if source == .textMarkers, text.utf16.count > first.text.utf16.count,
                       text.contains(first.text) {
                        if span == .consistent,
                           gesture?.coversBothEndpoints(provenBounds) == false,
                           gesture?.coversBothEndpoints(snapshot.bounds) == true {
                            proven = candidate
                            provenBounds = snapshot.bounds
                            resolution.acceptedMarkerExpansion += 1
                        } else {
                            resolution.preventedWidening += 1
                        }
                    }
                } else {
                    proven = candidate
                    provenBounds = snapshot.bounds
                }
            case .unverifiable:
                // Preserve the foreground best-effort fallback, but prefer an
                // actually gesture-proven range before emitting boundless text.
                if unproven == nil {
                    unproven = LiveSelectionCandidate(text: text, tier: tier, source: source, evidence: evidence)
                }
            }
        }
        return proven ?? unproven
    }

    private func prefersPointerSelection(
        _ pointer: LiveSelectionCandidate?, over marker: LiveSelectionCandidate
    ) -> Bool {
        guard checksDragSpan, !requiresGestureBounds, gestureInSourceWindow == true,
              let pointer, pointer.tier == .pointerElement, pointer.source == .selectedText,
              marker.source == .textMarkers,
              marker.text.utf16.count > pointer.text.utf16.count else { return false }
        return marker.text.contains(pointer.text)
    }

    private static func meaningful(_ text: String?) -> String? {
        guard let text,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }
}

/// Live read-only probe bound to one source process. It only copies attribute
/// values; there is no setter or action anywhere in this type.
final class LiveAccessibilitySelectionProbe: LiveSelectionAccessibilityProbe {
    // Undocumented-but-stable WebKit/Chromium attribute names used by
    // VoiceOver. Reading them is a normal public-API copy with no side effect
    // beyond the app answering an Accessibility query.
    private static let selectedTextMarkerRange = "AXSelectedTextMarkerRange"
    private static let stringForTextMarkerRange = "AXStringForTextMarkerRange"
    private static let boundsForTextMarkerRange = "AXBoundsForTextMarkerRange"

    private let application: AXUIElement
    private let deadline: UInt64
    private var snapshots: [(AXUIElement, LiveSelectionTextSource, LiveSelectionSnapshot?)] = []
    // One probe belongs to one serial attempt. Counts only: never retain failed
    // attribute values or selected text for diagnostics.
    private(set) var incompleteMessages = 0
    private(set) var missingMarkerRanges = 0
    private(set) var unavailableMarkerText = 0

    init(processIdentifier: pid_t, budget: TimeInterval) {
        application = AXUIElementCreateApplication(processIdentifier)
        deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(0, budget) * 1_000_000_000)
        Self.limitMessaging(application)
    }

    var isExpired: Bool { DispatchTime.now().uptimeNanoseconds >= deadline }

    func focusedElement() -> AXUIElement? {
        element(kAXFocusedUIElementAttribute, of: application)
    }

    func element(at point: CGPoint) -> AXUIElement? {
        guard !isExpired else { return nil }
        // Passing the application element restricts the hit test to this
        // app's own windows; the system-wide element would return whatever
        // other app's window happened to be on top.
        var hit: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(
            application, Float(point.x), Float(point.y), &hit
        )
        if result == .cannotComplete { incompleteMessages += 1 }
        guard result == .success, let hit else {
            return nil
        }
        Self.limitMessaging(hit)
        return hit
    }

    func parent(of element: AXUIElement) -> AXUIElement? {
        self.element(kAXParentAttribute, of: element)
    }

    func role(of element: AXUIElement) -> String? {
        copy(kAXRoleAttribute, of: element) as? String
    }

    func subrole(of element: AXUIElement) -> String? {
        copy(kAXSubroleAttribute, of: element) as? String
    }

    func selection(of element: AXUIElement, source: LiveSelectionTextSource) -> LiveSelectionSnapshot? {
        if let cached = snapshots.first(where: { CFEqual($0.0, element) && $0.1 == source }) {
            return cached.2
        }
        let snapshot = readSelection(of: element, source: source)
        // One bounded attempt only. Reuse each exact range token's text/bounds
        // rather than rereading the same representations for every fallback.
        snapshots.append((element, source, snapshot))
        return snapshot
    }

    private func readSelection(of element: AXUIElement, source: LiveSelectionTextSource) -> LiveSelectionSnapshot? {
        switch source {
        case .selectedRange:
            guard let range = selectedRange(of: element),
                  let text = parameterized(kAXStringForRangeParameterizedAttribute, of: element,
                                           parameter: range) as? String else { return nil }
            return LiveSelectionSnapshot(text: text, bounds: Self.rect(parameterized(
                kAXBoundsForRangeParameterizedAttribute, of: element, parameter: range)))
        case .textMarkers:
            guard !isExpired else { return nil }
            guard let markers = copy(Self.selectedTextMarkerRange, of: element) else {
                missingMarkerRanges += 1
                return nil
            }
            guard let text = parameterized(Self.stringForTextMarkerRange, of: element,
                                           parameter: markers) as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                unavailableMarkerText += 1
                return nil
            }
            return LiveSelectionSnapshot(text: text, bounds: Self.rect(parameterized(
                Self.boundsForTextMarkerRange, of: element, parameter: markers)))
        case .selectedText:
            guard let text = copy(kAXSelectedTextAttribute, of: element) as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            // AXSelectedText has no range token. Borrow geometry only from a
            // representation whose exact text agrees; never pair it blindly
            // with the host's possibly stale web-marker selection.
            for source in [LiveSelectionTextSource.selectedRange, .textMarkers] {
                if let correlated = selection(of: element, source: source),
                   correlated.text == text, correlated.bounds != nil {
                    return correlated
                }
            }
            return LiveSelectionSnapshot(text: text, bounds: nil)
        }
    }

    func isSame(_ lhs: AXUIElement, _ rhs: AXUIElement) -> Bool {
        CFEqual(lhs, rhs)
    }

    private func selectedRange(of element: AXUIElement) -> AXValue? {
        guard let value = copy(kAXSelectedTextRangeAttribute, of: element),
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        let axValue = value as! AXValue
        var range = CFRange()
        guard AXValueGetType(axValue) == .cfRange,
              AXValueGetValue(axValue, .cfRange, &range),
              range.location >= 0, range.length > 0 else {
            return nil
        }
        return axValue
    }

    private func element(_ attribute: String, of element: AXUIElement) -> AXUIElement? {
        guard let value = copy(attribute, of: element),
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        let child = value as! AXUIElement
        Self.limitMessaging(child)
        return child
    }

    private func copy(_ attribute: String, of element: AXUIElement) -> CFTypeRef? {
        guard !isExpired else { return nil }
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        if result == .cannotComplete { incompleteMessages += 1 }
        guard result == .success else {
            return nil
        }
        return value
    }

    private func parameterized(
        _ attribute: String,
        of element: AXUIElement,
        parameter: CFTypeRef
    ) -> CFTypeRef? {
        guard !isExpired else { return nil }
        var value: CFTypeRef?
        let result = AXUIElementCopyParameterizedAttributeValue(
            element, attribute as CFString, parameter, &value
        )
        if result == .cannotComplete { incompleteMessages += 1 }
        guard result == .success else {
            return nil
        }
        return value
    }

    private static func rect(_ value: CFTypeRef?) -> CGRect? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        var rect = CGRect.zero
        guard AXValueGetType(axValue) == .cgRect,
              AXValueGetValue(axValue, .cgRect, &rect) else {
            return nil
        }
        return rect
    }

    /// Per-element: the timeout applies only to messages sent through this
    /// element reference, so delivery's own Accessibility calls elsewhere in
    /// VoiceInk++ keep their existing behavior.
    private static func limitMessaging(_ element: AXUIElement) {
        _ = AXUIElementSetMessagingTimeout(element, LiveSelectionReadPolicy.messagingTimeout)
    }
}

enum LiveSelectionTextReader {
    /// One Accessibility attempt, off MainActor so a slow app cannot stall the
    /// recorder HUD. Bounded by the probe budget and messaging timeout.
    static func resolveAccessibility(
        processIdentifier: pid_t,
        gesture: LiveSelectionGesture?,
        requiresGestureBounds: Bool = false,
        checksDragSpan: Bool = false,
        sourceWindowBounds: CGRect? = nil
    ) async -> LiveSelectionResolution {
        await Task.detached(priority: .userInitiated) { () -> LiveSelectionResolution in
            guard AXIsProcessTrusted() else {
                var untrusted = LiveSelectionResolution()
                untrusted.accessibilityTrusted = false
                return untrusted
            }
            let inSourceWindow = gesture?.touchesWindow(
                ownedBy: processIdentifier, in: LiveSelectionWindow.onScreen()
            )
            let probe = LiveAccessibilitySelectionProbe(
                processIdentifier: processIdentifier,
                budget: LiveSelectionReadPolicy.accessibilityBudget
            )
            var resolution = LiveSelectionAccessibilityResolver(
                probe: probe, gesture: gesture, gestureInSourceWindow: inSourceWindow,
                requiresGestureBounds: requiresGestureBounds,
                checksDragSpan: checksDragSpan, sourceWindowBounds: sourceWindowBounds
            ).resolve()
            resolution.incompleteMessages = probe.incompleteMessages
            resolution.missingMarkerRanges = probe.missingMarkerRanges
            resolution.unavailableMarkerText = probe.unavailableMarkerText
            resolution.budgetExhausted = probe.isExpired
            return resolution
        }.value
    }
}

/// Bounded AppleScript sources for the browser overrides. The JavaScript is a
/// fixed constant, so plain literal escaping is sufficient; no page or user
/// text is ever interpolated into a script.
enum LiveSelectionBrowserScript {
    static func literal(_ javascript: String) -> String {
        "\"" + javascript
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// `is running` keeps a browser that quit between the frontmost check and
    /// the script from being relaunched by `tell application`.
    static func chromium(bundleID: String, javascript: String) -> String {
        "if application id \"\(bundleID)\" is running then\n"
            + "tell application id \"\(bundleID)\"\n"
            + "tell active tab of front window\n"
            + "return (execute javascript \(literal(javascript)))\n"
            + "end tell\nend tell\nend if\nreturn \"\""
    }

    static func safari(bundleID: String, javascript: String) -> String {
        "if application id \"\(bundleID)\" is running then\n"
            + "tell application id \"\(bundleID)\"\n"
            + "return (do JavaScript \(literal(javascript)) in current tab of front window)\n"
            + "end tell\nend if\nreturn \"\""
    }
}

/// Last-resort override for browsers SelectedTextKit already proved scriptable.
/// Chrome is excluded because its richer DOM probe already ran first. Requires
/// the browser's own "Allow JavaScript from Apple Events" setting plus macOS
/// Automation consent; either being off simply yields nothing.
enum LiveSelectionBrowserScriptReader {
    enum Engine: Equatable {
        case safari
        case chromium
    }

    /// Reads the DOM selection, or the selected range of a focused text
    /// control. Password inputs are excluded explicitly: their selection API
    /// would otherwise expose the secret behind the dots.
    static let selectionJavaScript = #"(()=>{const s=window.getSelection();let t=s?s.toString():'';if(!t){const a=document.activeElement;if(a&&a.type!=='password'&&typeof a.selectionStart==='number'&&typeof a.selectionEnd==='number'&&typeof a.value==='string'){t=a.value.slice(a.selectionStart,a.selectionEnd)}}return JSON.stringify({text:t})})()"#

    static func parseSelectionResult(_ output: String) -> String? {
        // Frame source text as JSON so osascript's own trailing newline can be
        // discarded by the parser without trimming selected indentation or
        // leading/trailing blank lines. Empty whitespace is still not context.
        guard let data = output.data(using: .utf8),
              let fields = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let text = fields["text"], text.contains(where: { !$0.isWhitespace }) else { return nil }
        return text
    }

    /// Browser scripting cannot prove a selection's screen bounds. A known
    /// gesture outside this browser's windows must not repeat an older tab
    /// selection; an unavailable window list remains best-effort evidence.
    static func mayReadForGesture(
        _ gesture: LiveSelectionGesture?,
        processIdentifier: pid_t,
        windows: [LiveSelectionWindow]
    ) -> Bool {
        gesture?.touchesWindow(ownedBy: processIdentifier, in: windows) != false
    }

    static func engine(for bundleID: String?) -> Engine? {
        switch bundleID {
        case "com.apple.Safari"?:
            return .safari
        case "com.microsoft.edgemac"?:
            return .chromium
        default:
            return nil
        }
    }

    static func source(for bundleID: String?) -> String? {
        guard let bundleID, let engine = engine(for: bundleID) else { return nil }
        switch engine {
        case .safari:
            return LiveSelectionBrowserScript.safari(bundleID: bundleID, javascript: selectionJavaScript)
        case .chromium:
            return LiveSelectionBrowserScript.chromium(bundleID: bundleID, javascript: selectionJavaScript)
        }
    }

    static func read(bundleID: String?) async -> String? {
        guard let source = source(for: bundleID),
              let result = try? await BoundedAppleScriptRunner.run(
                  source: source, timeout: LiveSelectionReadPolicy.browserScriptTimeout
              ) else {
            return nil
        }
        return parseSelectionResult(result.stdout)
    }
}

/// Counts-and-tier-only diagnostics. Selected text, page URLs, titles, and
/// window names never enter these messages.
enum LiveSelectionDiagnostics {
    private static let logger = Logger(
        subsystem: "com.ethansk.VoiceInkPlusPlus", category: "LiveSelection"
    )

    static func captured(
        tier: LiveSelectionTier,
        source: LiveSelectionTextSource?,
        evidence: LiveSelectionBoundsEvidence?,
        attempt: Int,
        bundleID: String?,
        startedAt: UInt64,
        span: LiveSelectionSpanEvidence = .unverifiable,
        length: Int = 0,
        observedOverextended: Int = 0,
        preventedWidening: Int = 0,
        acceptedMarkerExpansion: Int = 0,
        clickCount: Int? = nil,
        callbackLagMilliseconds: Int? = nil
    ) {
        // Historical .info captures were not retained, leaving real overcapture
        // untraceable. Persist only enum/count decisions, never text or geometry.
        logger.notice(
            "Live selection captured tier=\(tier.rawValue, privacy: .public) source=\(source?.rawValue ?? "none", privacy: .public) evidence=\(evidence?.rawValue ?? "none", privacy: .public) span=\(span.rawValue, privacy: .public) chars=\(length, privacy: .public) overextended=\(observedOverextended, privacy: .public) preventedWidening=\(preventedWidening, privacy: .public) markerExpansion=\(acceptedMarkerExpansion, privacy: .public) clicks=\(clickCount ?? 0, privacy: .public) maxCallbackLagMs=\(callbackLagMilliseconds ?? -1, privacy: .public) attempt=\(attempt, privacy: .public) bundle=\(bundleID ?? "unknown", privacy: .public) durationMs=\(elapsedMilliseconds(since: startedAt), privacy: .public)"
        )
    }

    static func unavailable(
        _ resolution: LiveSelectionResolution,
        attempts: Int,
        bundleID: String?,
        startedAt: UInt64
    ) {
        logger.notice(
            "Live selection unavailable trusted=\(resolution.accessibilityTrusted, privacy: .public) attempts=\(attempts, privacy: .public) examined=\(resolution.examinedElements, privacy: .public) elsewhere=\(resolution.rejectedElsewhere, privacy: .public) overextended=\(resolution.observedOverextended, privacy: .public) preventedWidening=\(resolution.preventedWidening, privacy: .public) outsideSourceWindow=\(resolution.rejectedOutsideSourceWindow, privacy: .public) secure=\(resolution.refusedSecure, privacy: .public) hasGesture=\(resolution.hasGesture, privacy: .public) emptyHitTests=\(resolution.emptyHitTests, privacy: .public) unverifiable=\(resolution.rejectedUnverifiable, privacy: .public) cannotComplete=\(resolution.incompleteMessages, privacy: .public) missingMarkers=\(resolution.missingMarkerRanges, privacy: .public) unavailableMarkerText=\(resolution.unavailableMarkerText, privacy: .public) degenerateBounds=\(resolution.degenerateBounds, privacy: .public) budgetExhausted=\(resolution.budgetExhausted, privacy: .public) bundle=\(bundleID ?? "unknown", privacy: .public) durationMs=\(elapsedMilliseconds(since: startedAt), privacy: .public)"
        )
    }

    /// The watcher intentionally samples the current pointer, not reconstructed
    /// event geometry. Report delayed callbacks and pre-read drops without
    /// logging pointer coordinates, application text or performing extra reads.
    static func gesture(outcome: String, clickCount: Int, callbackLagMilliseconds: Int) {
        logger.notice(
            "Live selection gesture outcome=\(outcome, privacy: .public) clicks=\(clickCount, privacy: .public) callbackLagMs=\(callbackLagMilliseconds, privacy: .public)"
        )
    }

    /// One persisted, text-free outcome per attempted gesture. Info-only AX
    /// traces were absent from historical logs, and a successful AX read did
    /// not prove that focus/cancellation checks allowed it into the HUD.
    static func finished(outcome: String, bundleID: String?, startedAt: UInt64) {
        logger.notice(
            "Live selection finished outcome=\(outcome, privacy: .public) bundle=\(bundleID ?? "unknown", privacy: .public) durationMs=\(elapsedMilliseconds(since: startedAt), privacy: .public)"
        )
    }

    private static func elapsedMilliseconds(since start: UInt64) -> Int {
        let now = DispatchTime.now().uptimeNanoseconds
        return now > start ? Int((now - start) / 1_000_000) : 0
    }
}
