// Ethan's context acknowledgement (2026-11-24): when he highlights text or saves a
// screenshot while recording, the Recording Outline runs one visible lap in that
// context's transcript colour, blue for a selection and magenta for a screenshot,
// then hands the border back to the untouched rainbow. He can tell the context was
// captured without looking at the HUD. His 2026-11-26 refinement holds the whole
// border in that colour for at least a second. Presentation only.
// — Claude Opus 5.5; GPT-6.1 Sol
import SwiftUI

/// One colour source for the HUD context labels and their acceptance lap. The HUD
/// keeps its existing opacity and waiting-for-speech treatment; both consumers
/// resolve these same system colours in their own environment. — GPT-6.1 Sol
enum RecorderContextColor {
    static let selection = Color.cyan
    static let screenshot = Color.purple
}

/// One accepted highlight or screenshot. The recording session owns it, so every
/// mirrored panel draws the same lap from the same start time. A newer acceptance
/// replaces it, so there is never a queue and no callback outlives it.
///
/// This never touches capture, focus, Pause, media, the microphone, saved context
/// or either Primary/Next delivery route. — Claude Opus 5.5
struct RecorderContextAcceptancePulse: Equatable {
    enum Kind: Equatable {
        /// Highlighted text, or an approved Telegram/Codex selection image.
        case selection
        /// A saved macOS screenshot.
        case screenshot

        var color: Color {
            switch self {
            case .selection: return RecorderContextColor.selection
            case .screenshot: return RecorderContextColor.screenshot
            }
        }
    }

    let id: UUID
    let kind: Kind
    let startedAt: Date

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
}

/// Timing and shape of the acknowledgement lap. All of it is measured in the
/// rainbow's own moving frame. The lap launches from the stretch of border that
/// currently shows the colour closest to the context colour (Ethan's "where the
/// blue currently is"), then lands back in that band. The lap rides the rainbow's
/// phase but never changes it, so when the lap ends the border is exactly the
/// rainbow it would have been anyway. — Claude Opus 5.5
enum RecorderContextSweep {
    /// Ethan wants a full-colour acknowledgement for a good second minimum,
    /// rather than a short arc passing by. One head completes exactly one lap
    /// while the whole border holds its colour; short fades surround that hold.
    /// These are drawing times, never input/capture waits. — GPT-6.1 Sol
    static let fullColorDuration: TimeInterval = 1.2
    static let fadeInDuration: TimeInterval = 0.1
    static let fadeOutDuration: TimeInterval = 0.2
    static let duration = fadeInDuration + fullColorDuration + fadeOutDuration
    /// Reduce Motion: the whole border holds the context colour this long, with no
    /// movement or fade, then returns to the still rainbow.
    static let stillDuration = fullColorDuration
    /// A white-hot spark rides the head. It is a colour along the same 1pt stroke,
    /// never a glow, blur or gradient into the panel.
    static let sparkHalfWidth = 0.035
    static let sparkWhiteness = 0.55

    struct Lap: Equatable {
        /// Distance travelled clockwise from the launch point, in laps, 0...1.
        let head: Double
        /// Fades the full-colour border in and out, with a 1.2s plateau. — GPT-6.1 Sol
        let strength: Double
    }

    enum Form: Equatable {
        case lap(Lap)
        /// Reduce Motion's static acknowledgement.
        case still
    }

    struct Acknowledgement: Equatable {
        let kind: RecorderContextAcceptancePulse.Kind
        let form: Form
    }

    /// The moving lap at `date`, or nil before it starts and once it has finished.
    /// The outline then draws the plain rainbow, so an expired pulse can never leave
    /// a colour behind and needs no timer to clear it.
    static func acknowledgement(for pulse: RecorderContextAcceptancePulse?, at date: Date) -> Acknowledgement? {
        guard let pulse else { return nil }
        let progress = date.timeIntervalSince(pulse.startedAt) / duration
        guard progress >= 0, progress < 1 else { return nil }
        return Acknowledgement(kind: pulse.kind, form: .lap(lap(atProgress: progress)))
    }

    /// The head travels only during the fully coloured hold. Both short fades
    /// reach zero at the endpoints and leave the underlying flow untouched.
    /// — Claude Opus 5.5; GPT-6.1 Sol
    static func lap(atProgress progress: Double) -> Lap {
        let elapsed = progress * duration
        return Lap(
            head: smoothstep((elapsed - fadeInDuration) / fullColorDuration),
            strength: smoothstep(elapsed / fadeInDuration)
                * smoothstep((duration - elapsed) / fadeOutDuration)
        )
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

    /// The spectrum position whose colour is nearest `tint`. The lap launches and
    /// lands here, so it grows out of and folds back into its own colour band.
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
    let tint: RecorderNeonSpectrum.Components
    let origin: Double
    let form: RecorderContextSweep.Form

    init(tint: RecorderNeonSpectrum.Components, form: RecorderContextSweep.Form) {
        self.tint = tint
        self.form = form
        origin = RecorderContextSweep.origin(nearest: tint)
    }

    /// `position` locates the pulse mask. Loading can move the rainbow beneath it
    /// differently, so the caller supplies that actual colour position separately.
    /// Uncovered/zero-strength pixels then keep their real rainbow colour.
    /// Found and fixed by GPT-6.1 Sol. — GPT-6.1 Sol
    func components(at position: Double, rainbowPosition: Double? = nil) -> RecorderNeonSpectrum.Components {
        let rainbow = RecorderNeonSpectrum.components(at: rainbowPosition ?? position)
        guard case .lap(let lap) = form else { return tint }

        let sweep = RecorderContextSweep.self
        let lapOffset = (position - origin) - (position - origin).rounded(.down)
        let distance = abs(lapOffset - lap.head)
        let nearHead = max(0, 1 - min(distance, 1 - distance) / sweep.sparkHalfWidth)
        // The whole stroke stays tinted while one small highlight travels around
        // it. No rainbow leaks through the hold, even as its own clock accelerates.
        // This replaces the former half-border arc, not the shared motion clock.
        // — GPT-6.1 Sol
        let highlighted = Self.mix(tint, .init(red: 1, green: 1, blue: 1),
                                   nearHead * nearHead * sweep.sparkWhiteness)
        return Self.mix(rainbow, highlighted, lap.strength)
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
