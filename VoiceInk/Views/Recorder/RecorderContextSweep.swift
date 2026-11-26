// Ethan's context acknowledgement: when he highlights text or saves a screenshot
// while recording, the Recording Outline answers in that context's transcript
// colour, blue for a selection and magenta for a screenshot, so he can tell the
// context was captured without looking at the HUD. Explicit Cancel / Won’t paste
// uses the same entrance, hold and return in red. — GPT-6.1 Sol
//
// His 2026-11-26 correction defines one continuous entrance and exit, not separate
// laps: the colour travels round from its own band until it fills the whole
// outline, the entire stroke then holds that colour briefly while it
// keeps flowing, and finally the rainbow travels back in behind it. He rejected
// both a static whole-edge flash without the travelling entrance (build 556) and
// two replayed one-second laps, whose rainbow break between them looked like a
// second launch (cf6323cb). Presentation only. — Claude Opus 5.5; GPT-6.1 Sol
import SwiftUI

/// One colour source for the HUD context labels and their outline acknowledgement. The HUD
/// keeps its existing opacity and waiting-for-speech treatment; both consumers
/// resolve these same system colours in their own environment. — GPT-6.1 Sol
enum RecorderContextColor {
    static let selection = Color.cyan
    static let screenshot = Color.purple
    static let noPaste = AppTheme.Status.error
}

/// One accepted highlight, screenshot or explicit no-paste outcome. The recording
/// session owns it, so every
/// mirrored panel draws the same acknowledgement from the same start time. A newer
/// acceptance replaces it, so there is never a queue and no callback outlives it.
///
/// This never touches capture, focus, Pause, media, the microphone, saved context
/// or either Primary/Next delivery route. — Claude Opus 5.5
struct RecorderContextAcceptancePulse: Equatable {
    enum Kind: Equatable {
        /// Highlighted text, or an approved Telegram/Codex selection image.
        case selection
        /// A saved macOS screenshot.
        case screenshot
        /// Ethan's red acknowledgement for Cancel / Won't paste. The normal
        /// spectrum still avoids pure red; only this explicit action uses it.
        /// — GPT-6.1 Sol
        case noPaste

        var color: Color {
            switch self {
            case .selection: return RecorderContextColor.selection
            case .screenshot: return RecorderContextColor.screenshot
            case .noPaste: return RecorderContextColor.noPaste
            }
        }
    }

    let id: UUID
    let kind: Kind
    let startedAt: Date
    /// Previous colour geometry beneath this entrance, plus its last opaque base.
    /// It stays beneath the new colour until this entrance fills the ring, so rapid
    /// highlights cannot expose the rainbow again. One bounded value is kept;
    /// there is no recursive history, animation queue or input wait.
    /// — Claude Opus 5.5; GPT-6.1 Sol
    private(set) var replaced: RecorderContextSweep.Underlay? = nil

    /// Explicit UI outcomes share the accepted context animation. Constructing a
    /// pulse never changes capture or output policy. — GPT-6.1 Sol
    init(kind: Kind, at date: Date, id: UUID = UUID()) {
        self.id = id
        self.kind = kind
        startedAt = date
    }

    /// Typed prose and internal speech-timing markers are not captured context,
    /// so they launch nothing. — Claude Opus 5.5
    init?(accepting reference: LiveSelectionReference, at date: Date, id: UUID = UUID()) {
        if reference.isScreenshot {
            kind = .screenshot
        } else if reference.isSelection {
            kind = .selection
        } else {
            return nil
        }
        self.id = id
        startedAt = date
    }

    /// This pulse taking over from `previous`, which may still be showing. A
    /// finished or not-yet-visible previous pulse leaves nothing behind. — Claude Opus 5.5
    func replacing(_ previous: RecorderContextAcceptancePulse?) -> RecorderContextAcceptancePulse {
        var pulse = self
        pulse.replaced = previous.flatMap { RecorderContextSweep.underlay(freezing: $0, at: startedAt) }
        return pulse
    }
}

/// A tiny visual receipt after a card finishes: no session, transcript, audio or
/// destination is retained. Its original pulse time prevents a fast cancellation
/// from disappearing before the red animation has shown. — GPT-6.1 Sol
struct RecorderNoPasteFeedback: Equatable, Identifiable {
    enum Reason: Equatable {
        case cancelled, clipboardOnly

        var title: String {
            self == .cancelled ? String(localized: "Cancelled") : String(localized: "Won’t paste")
        }

        var symbol: String { self == .cancelled ? "xmark.circle.fill" : "nosign" }
    }

    let id: UUID
    let pulse: RecorderContextAcceptancePulse
    let reason: Reason
    let activity: RecorderOutlineActivity?
    let isProcessing: Bool
    let processingStartedAt: Date?

    func remaining(at date: Date, reducedMotion: Bool) -> TimeInterval? {
        let duration = reducedMotion ? RecorderContextSweep.stillDuration : RecorderContextSweep.duration
        let end = pulse.startedAt.addingTimeInterval(duration)
        guard date >= pulse.startedAt, date < end else { return nil }
        return end.timeIntervalSince(date)
    }
}

/// Timing and shape of the acknowledgement. All of it is measured in the rainbow's
/// own moving frame. The colour launches from the stretch of border that currently
/// shows the rainbow colour closest to it (Ethan's "where the blue currently is"),
/// grows clockwise until it closes the ring there, holds, and then the rainbow
/// returns along the same path and the colour lands back in that band. It rides the
/// rainbow's phase but never changes it, so afterwards the border is exactly the
/// rainbow it would have been anyway. — Claude Opus 5.5
enum RecorderContextSweep {
    /// Entrance: the head travels once round from the launch band and closes the
    /// ring, leaving the whole stroke in the context colour. — Claude Opus 5.5
    static let entranceDuration: TimeInterval = 0.7
    /// Ethan approved the animation, then asked for half of the previous 1.2s full
    /// colour hold. Only this hold shortens; the entrance and exit stay 0.7s.
    /// This replaces his earlier one-second minimum. — Claude Opus 5.5; GPT-6.1 Sol
    static let holdDuration: TimeInterval = 0.6
    /// Exit: the rainbow travels back round behind a soft edge, following the
    /// same direction, and the last of the colour lands in its launch band. — Claude Opus 5.5
    static let exitDuration: TimeInterval = 0.7
    static let duration = entranceDuration + holdDuration + exitDuration
    /// Reduce Motion: the whole border holds the context colour this long, with no
    /// movement or fade, then returns to the still rainbow.
    static let stillDuration: TimeInterval = holdDuration
    /// The colour ignites over this long at launch and fades over the landing
    /// interval, reaching exactly zero at both ends so neither can jump. — Claude Opus 5.5
    static let launchFade: TimeInterval = 0.06
    static let landingFade: TimeInterval = 0.1
    /// Edge softness in laps. The head is crisp so its direction reads clearly;
    /// the returning rainbow dissolves in behind a soft tail. They span about two
    /// and six of the outline's 72 colour stops, so the edges glide rather than step. — Claude Opus 5.5
    static let headFeather = 0.025
    static let tailFeather = 0.09
    /// A white-hot spark rides the head. It is a colour along the same 1pt stroke,
    /// never a glow, blur or gradient into the panel.
    static let sparkHalfWidth = 0.035
    static let sparkWhiteness = 0.55
    /// Once the ring closes, the spark melts into the full colour over this long. — Claude Opus 5.5
    static let sparkSettle: TimeInterval = 0.3
    /// While the colour shows, one soft lighter band in that same colour rides the
    /// rainbow's flow, so the steady colour still visibly travels round. Mixing
    /// toward white keeps its hue and never shows a rainbow colour. — Claude Opus 5.5
    static let sheenWhiteness = 0.2

    struct Lap: Equatable {
        /// The colour's leading edge, travelled clockwise from the launch band, in
        /// laps 0...1. It reaches 1, closing the ring, at the end of the entrance. — Claude Opus 5.5
        let head: Double
        /// The returning rainbow's edge, 0...1. It stays 0 until the exit begins. — Claude Opus 5.5
        let tail: Double
        /// Fades the colour in at launch and out on landing, 0...1. — Claude Opus 5.5
        let strength: Double
        /// The spark on the head, 0...1: lit while the head travels, settling
        /// away once the ring has closed. — Claude Opus 5.5
        let spark: Double
    }

    /// A previous arc's fixed geometry and optional opaque base beneath the new
    /// entrance; colour flow still follows the leaf clock. — Claude Opus 5.5; GPT-6.1 Sol
    struct Underlay: Equatable {
        let kind: RecorderContextAcceptancePulse.Kind
        let lap: Lap
        /// Keep the last fully coloured background beneath rapid replacements.
        /// One colour plus one frozen arc is bounded; retaining previous pulses
        /// recursively would grow with every selection. Found and fixed by GPT-6.1 Sol.
        let backgroundKind: RecorderContextAcceptancePulse.Kind?

        /// The opaque colour this snapshot can safely pass to its replacement.
        /// A partial arc alone never proves the whole border was filled. — GPT-6.1 Sol
        var opaqueBackgroundKind: RecorderContextAcceptancePulse.Kind? {
            lap.head == 1 && lap.tail == 0 && lap.strength == 1 ? kind : backgroundKind
        }
    }

    enum Form: Equatable {
        case lap(Lap)
        /// Reduce Motion's static acknowledgement.
        case still
    }

    struct Acknowledgement: Equatable {
        let kind: RecorderContextAcceptancePulse.Kind
        let form: Form
        /// Only during the entrance: what the new colour is painting over. — Claude Opus 5.5
        var underlay: Underlay? = nil
    }

    /// The acknowledgement at `date`, or nil before it starts and once it has
    /// finished. The outline then draws the plain rainbow, so an expired pulse can
    /// never leave a colour behind and needs no clock of its own to clear it. — Claude Opus 5.5
    static func acknowledgement(for pulse: RecorderContextAcceptancePulse?, at date: Date) -> Acknowledgement? {
        // Compare the representable end Date, as the Reduce Motion hold does.
        // Elapsed subtraction can round down at the fractional2.6s endpoint.
        // Found and fixed by GPT-6.1 Sol.
        guard let pulse, date < pulse.startedAt.addingTimeInterval(duration) else { return nil }
        var elapsed = date.timeIntervalSince(pulse.startedAt)
        // A frame may carry a timestamp a moment before the acceptance it now
        // shows. With a colour already on screen, hold that colour rather than
        // flashing the rainbow for that frame.
        if elapsed < 0, pulse.replaced != nil { elapsed = 0 }
        guard elapsed >= 0 else { return nil }
        // The replaced colour matters only ahead of the new head. Once the ring
        // closes the new colour covers it, and the exit must reveal the rainbow.
        return Acknowledgement(kind: pulse.kind, form: .lap(lap(atElapsed: elapsed)),
                               underlay: elapsed < entranceDuration ? pulse.replaced : nil)
    }

    /// One continuous curve: the head eases once round, the whole stroke holds,
    /// then the tail eases once round. Neither edge ever reverses or restarts. — Claude Opus 5.5
    static func lap(atElapsed elapsed: TimeInterval) -> Lap {
        let exitStarts = entranceDuration + holdDuration
        return Lap(
            head: smoothstep(elapsed / entranceDuration),
            tail: smoothstep((elapsed - exitStarts) / exitDuration),
            strength: smoothstep(elapsed / launchFade) * smoothstep((duration - elapsed) / landingFade),
            spark: 1 - smoothstep((elapsed - entranceDuration) / sparkSettle)
        )
    }

    /// `pulse` as it looks at `date`, without its spark, for a newer pulse to paint
    /// over. Nil once it has finished or while it is still invisible. — Claude Opus 5.5
    static func underlay(freezing pulse: RecorderContextAcceptancePulse, at date: Date) -> Underlay? {
        guard date >= pulse.startedAt,
              date < pulse.startedAt.addingTimeInterval(duration) else { return nil }
        let elapsed = date.timeIntervalSince(pulse.startedAt)
        let frozen = lap(atElapsed: elapsed)
        // An immediate third gesture must retain the colour the second gesture
        // was just about to cover, even before its own ink appears.
        // Found and fixed by GPT-6.1 Sol.
        guard frozen.strength > 0 else { return pulse.replaced }
        return Underlay(kind: pulse.kind,
                        lap: Lap(head: frozen.head, tail: frozen.tail, strength: frozen.strength, spark: 0),
                        backgroundKind: pulse.replaced?.opaqueBackgroundKind)
    }

    /// How much of Reduce Motion's still acknowledgement remains, or nil once it is
    /// over. A clock that reads earlier than the start still yields at most
    /// `stillDuration`, so the hold is always bounded.
    static func stillRemaining(of pulse: RecorderContextAcceptancePulse, at date: Date) -> TimeInterval? {
        // Compare the same representable Date deadline used by callers. Subtracting
        // elapsed time from a fractional hold could leave nanoseconds at the nominal
        // endpoint. — GPT-6.1 Sol
        let deadline = pulse.startedAt.addingTimeInterval(stillDuration)
        guard date < deadline else { return nil }
        return stillDuration - max(0, date.timeIntervalSince(pulse.startedAt))
    }

    /// The spectrum position whose colour is nearest `tint`. The colour launches
    /// and lands here, so it grows out of and folds back into its own colour band. — Claude Opus 5.5
    static func origin(nearest tint: RecorderNeonSpectrum.Components) -> Double {
        let steps = RecorderNeonSpectrum.anchors.count * 32
        var best = 0.0
        var bestDistance = Double.infinity
        for step in 0..<steps {
            let position = Double(step) / Double(steps)
            let distance = squaredDistance(RecorderNeonSpectrum.components(at: position), tint)
            if distance < bestDistance {
                best = position
                bestDistance = distance
            }
        }
        return best
    }

    /// The transcript colour as concrete sRGB, as this panel would draw that text.
    static func components(of color: Color, in environment: EnvironmentValues) -> RecorderNeonSpectrum.Components {
        let resolved = color.resolve(in: environment)
        func unit(_ value: Float) -> Double { min(max(Double(value), 0), 1) }
        return RecorderNeonSpectrum.Components(
            red: unit(resolved.red), green: unit(resolved.green), blue: unit(resolved.blue))
    }

    /// The flowing sheen's brightness at a lap offset from the launch band: one
    /// soft band, brightest opposite the launch point and zero at it. — Claude Opus 5.5
    static func sheen(atOffset offset: Double) -> Double {
        let wave = 0.5 + 0.5 * cos(2 * Double.pi * (offset - 0.5))
        return wave * wave * wave
    }

    /// Hermite ease, 3x² − 2x³, on a clamped input.
    static func smoothstep(_ value: Double) -> Double {
        let x = min(max(value, 0), 1)
        return x * x * (3 - 2 * x)
    }

    static func squaredDistance(_ a: RecorderNeonSpectrum.Components, _ b: RecorderNeonSpectrum.Components) -> Double {
        let red = a.red - b.red
        let green = a.green - b.green
        let blue = a.blue - b.blue
        return red * red + green * green + blue * blue
    }
}

/// Colours the outline while an acknowledgement is showing. It is built once per
/// frame and queried at each of the outline's colour stops. — Claude Opus 5.5
struct RecorderContextSweepPaint {
    /// Extraction of the mask and spark math previously inside
    /// RecorderContextSweepPaint.components. Adds the flowing sheen and sharing
    /// with a replaced colour; this is not a behavior-neutral move. — GPT-6.1 Sol
    struct Layer {
        let tint: RecorderNeonSpectrum.Components
        let origin: Double
        let lap: RecorderContextSweep.Lap
        let backgroundTint: RecorderNeonSpectrum.Components?

        func paint(over base: RecorderNeonSpectrum.Components, at position: Double) -> RecorderNeonSpectrum.Components {
            let sweep = RecorderContextSweep.self
            let lapOffset = (position - origin) - (position - origin).rounded(.down)
            var cover = 0.0
            var spark = 0.0
            // The feathers can straddle the launch point, so test this stop one lap
            // behind and ahead as well. With the head at 1 and the tail at 0 every
            // stop is fully covered: that is the hold.
            for x in [lapOffset - 1, lapOffset, lapOffset + 1] {
                let afterTail = sweep.smoothstep((x - lap.tail + sweep.tailFeather) / sweep.tailFeather)
                let beforeHead = 1 - sweep.smoothstep((x - lap.head) / sweep.headFeather)
                cover = max(cover, afterTail * beforeHead)
                let nearHead = max(0, 1 - abs(x - lap.head) / sweep.sparkHalfWidth)
                spark = max(spark, nearHead * nearHead)
            }
            let tinted = RecorderContextSweepPaint.mix(backgroundTint ?? base, tint, cover * lap.strength)
            // Spark and sheen only lighten the context colour toward white, so the
            // hold keeps its hue and never shows the rainbow beneath it.
            let sheen = sweep.sheenWhiteness * sweep.sheen(atOffset: lapOffset) * cover
            let white = max(spark * sweep.sparkWhiteness * lap.spark, sheen) * lap.strength
            return RecorderContextSweepPaint.mix(tinted, .init(red: 1, green: 1, blue: 1), white)
        }
    }

    let tint: RecorderNeonSpectrum.Components
    let origin: Double
    let form: RecorderContextSweep.Form
    /// The replaced acknowledgement still showing ahead of this entrance, if any. — Claude Opus 5.5
    let underlay: Layer?

    init(tint: RecorderNeonSpectrum.Components, form: RecorderContextSweep.Form, underlay: Layer? = nil) {
        self.tint = tint
        self.form = form
        self.underlay = underlay
        origin = RecorderContextSweep.origin(nearest: tint)
    }

    /// `position` locates the pulse mask. Loading can move the rainbow beneath it
    /// differently, so the caller supplies that actual colour position separately.
    /// Uncovered/zero-strength pixels then keep their real rainbow colour.
    /// Found and fixed by GPT-6.1 Sol. — GPT-6.1 Sol
    func components(at position: Double, rainbowPosition: Double? = nil) -> RecorderNeonSpectrum.Components {
        let rainbow = RecorderNeonSpectrum.components(at: rainbowPosition ?? position)
        guard case .lap(let lap) = form else { return tint }
        let base = underlay?.paint(over: rainbow, at: position) ?? rainbow
        return Layer(tint: tint, origin: origin, lap: lap, backgroundTint: nil).paint(over: base, at: position)
    }

    func color(at position: Double, rainbowPosition: Double? = nil) -> Color {
        let value = components(at: position, rainbowPosition: rainbowPosition)
        return Color(.sRGB, red: value.red, green: value.green, blue: value.blue)
    }

    static func mix(_ from: RecorderNeonSpectrum.Components, _ to: RecorderNeonSpectrum.Components,
                    _ amount: Double) -> RecorderNeonSpectrum.Components {
        guard amount > 0 else { return from }
        guard amount < 1 else { return to }
        let t = amount
        return RecorderNeonSpectrum.Components(
            red: from.red + (to.red - from.red) * t,
            green: from.green + (to.green - from.green) * t,
            blue: from.blue + (to.blue - from.blue) * t
        )
    }
}

extension RecorderContextSweepPaint.Layer {
    /// A layer launching from `tint`'s own band. — Claude Opus 5.5
    init(tint: RecorderNeonSpectrum.Components, lap: RecorderContextSweep.Lap,
         backgroundTint: RecorderNeonSpectrum.Components? = nil) {
        self.init(tint: tint, origin: RecorderContextSweep.origin(nearest: tint), lap: lap,
                  backgroundTint: backgroundTint)
    }
}
