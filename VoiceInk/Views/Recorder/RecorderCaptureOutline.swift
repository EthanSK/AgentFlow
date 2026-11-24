// Ethan's "rainbow thing": a thin, sharp rainbow border on every mirrored
// Mini and Notch recorder card. His 2026-11-24 refinement explicitly removes
// blur and colour bleeding into the black panel. MiniRecorderView and NotchRecorderView
// draw it from `RecorderStateProvider.showsLiveCaptureOutline`; Settings ->
// Interface -> Recording Outline turns it off.
import SwiftUI

/// One sharp stroke follows the recorder's silhouette while its microphone is live.
/// Colour still flows evenly around the border; there is no bloom, pale core,
/// opacity flicker or interior shading. Reduce Motion holds the colours still.
///
/// Callers place it in a `.background` above the card fill and beneath content, and
/// the card's own clip bounds it, so it changes no geometry, hit target, drag
/// surface, scroll view or keyboard focus. This is capture state only. It never
/// marks a saved destination, a Next route or the current-focus icon.
/// Original design by Claude Opus 5.5; border-only refinement by GPT-6.1 Sol.
struct RecorderCaptureOutline<OutlineShape: Shape>: View, Animatable {
    var shape: OutlineShape
    /// Formerly `topEdgeFade`: the Notch keeps its open top with a sharp clip,
    /// without an opacity gradient into the black surface. Mini stays a closed ring.
    var omitsTopEdge = false

    // macOS exposes Reduce Motion as a read-only environment value. Hosted
    // appearance previews can exercise its static branch without changing the
    // user's system accessibility preference; real panels leave this nil.
    var reduceMotionForPreview: Bool? = nil
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { reduceMotionForPreview ?? systemReduceMotion }
    @State private var trace = RecorderCaptureOutlineTrace()

    /// Forwards the card shape's own animation, so the tube follows the clip through
    /// compact/expanded corner and size springs instead of snapping ahead of it and
    /// being cut off at the corners. — Claude Opus 5.5
    var animatableData: OutlineShape.AnimatableData {
        get { shape.animatableData }
        set { shape.animatableData = newValue }
    }

    var body: some View {
        // Only this leaf redraws per frame. The schedule exists only while the
        // outline is lit (callers remove the view otherwise), caps at 30 Hz and is
        // paused under Reduce Motion. Earlier recorder lag came from an independent
        // 60 Hz clock plus broad card invalidation (LEARNINGS, 2026-07-31), so this
        // never observes the session, the audio meter or the transcript.
        TimelineView(.animation(
            minimumInterval: RecorderCaptureOutlineStyle.frameInterval,
            paused: reduceMotion
        )) { timeline in
            let phase = reduceMotion ? 0 : RecorderCaptureOutlineStyle.flowPhase(at: timeline.date)
            Canvas { context, size in
                drawBorder(in: context, size: size, phase: phase)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // Former `drawNeonTube`: one stroke replaces its bloom and pale core.
    private func drawBorder(in context: GraphicsContext, size: CGSize, phase: Double) {
        let style = RecorderCaptureOutlineStyle.self
        let bounds = CGRect(origin: .zero, size: size)
        guard bounds.width > style.tubeInset * 4, bounds.height > style.tubeInset * 4 else { return }

        let cardPath = shape.path(in: bounds)
        // The same shape in a slightly smaller rect keeps the tube parallel to the
        // card edge, including the Notch flares, without needing an insettable shape.
        let tubePath = shape.path(in: bounds.insetBy(dx: style.tubeInset, dy: style.tubeInset))
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let samples = trace.samples(along: tubePath, around: center)
        guard !samples.isEmpty else { return }

        let tube = GraphicsContext.Shading.conicGradient(
            Gradient(stops: samples.map { sample in
                Gradient.Stop(
                    color: RecorderNeonSpectrum.color(at: sample.clockwiseFraction - phase),
                    location: sample.angularLocation
                )
            }),
            center: center
        )
        context.drawLayer { layer in
            layer.clip(to: cardPath)
            if omitsTopEdge {
                let top = style.tubeInset + style.tubeWidth / 2
                layer.clip(to: Path(CGRect(x: 0, y: top, width: size.width,
                                          height: max(0, size.height - top))))
            }
            layer.stroke(tubePath, with: tube, lineWidth: style.tubeWidth)
        }
    }
}

/// The persisted Recording Outline switch. It is on when no value has been saved
/// because Ethan asked for it by default, and an explicit false from Settings stays
/// off across launches: `@AppStorage` uses this default only for a missing key, so
/// no migration ever rewrites a saved choice. — Claude Opus 5.5
enum RecorderCaptureOutlinePreference {
    static let preferenceKey = "recorderCaptureOutlineEnabled"
    static let defaultValue = true
}

/// Border thickness and timing in recorder points, before whole-panel HUD scaling.
/// Ethan requested a thinner outline with no blur on 2026-11-24. — GPT-6.1 Sol
enum RecorderCaptureOutlineStyle {
    static let tubeInset: CGFloat = 0.5
    static let tubeWidth: CGFloat = 1
    /// One full trip around the card. Slow enough to stay peripheral while Ethan
    /// reads his live transcript, fast enough to read as alive. — Claude Opus 5.5
    static let lapDuration: TimeInterval = 5
    static let frameInterval: TimeInterval = 1.0 / 30.0

    /// Phase comes from the wall clock rather than per-view state, so every mirrored
    /// monitor shows the same colours at the same moment. — Claude Opus 5.5
    static func flowPhase(at date: Date) -> Double {
        (date.timeIntervalSinceReferenceDate / lapDuration).truncatingRemainder(dividingBy: 1)
    }
}

/// Neon tube colours rather than a mathematical HSV wheel, whose dark blue and
/// muddy yellow-green read as dull on black glass. Every anchor and blend between
/// them stays bright and saturated. No pure red is used, which keeps the cycle clear
/// of the red Stop and Won't paste signals. — Claude Opus 5.5
enum RecorderNeonSpectrum {
    struct Components: Equatable {
        let red: Double
        let green: Double
        let blue: Double
    }

    static let anchors: [Components] = [
        Components(red: 1.00, green: 0.16, blue: 0.80), // hot magenta
        Components(red: 0.60, green: 0.30, blue: 1.00), // electric violet
        Components(red: 0.16, green: 0.50, blue: 1.00), // laser blue
        Components(red: 0.00, green: 0.92, blue: 1.00), // neon cyan
        Components(red: 0.20, green: 1.00, blue: 0.52), // acid green
        Components(red: 1.00, green: 0.90, blue: 0.20), // sodium yellow
        Components(red: 1.00, green: 0.40, blue: 0.18)  // tube orange
    ]

    /// The colour at a cyclic position, where 0 and 1 are the same point.
    static func components(at position: Double) -> Components {
        let wrapped = position - position.rounded(.down)
        let scaled = wrapped * Double(anchors.count)
        let lowerIndex = min(Int(scaled), anchors.count - 1)
        let upperIndex = (lowerIndex + 1) % anchors.count
        let blend = scaled - Double(lowerIndex)
        let lower = anchors[lowerIndex]
        let upper = anchors[upperIndex]
        func channel(_ from: Double, _ to: Double) -> Double {
            from + (to - from) * blend
        }
        return Components(
            red: channel(lower.red, upper.red),
            green: channel(lower.green, upper.green),
            blue: channel(lower.blue, upper.blue)
        )
    }

    static func color(at position: Double) -> Color {
        let components = components(at: position)
        return Color(.sRGB, red: components.red, green: components.green, blue: components.blue)
    }
}

/// Spreads colour evenly along the tube. A plain conic gradient would cram most of
/// the rainbow into the middle of a wide card's long edges and barely change along
/// the rest. Instead this samples equal distances along the tube and places each
/// gradient stop at that point's angle from the centre. Samples are recomputed only
/// when the path changes (resizes and corner springs), never on ordinary flow
/// frames. — Claude Opus 5.5
final class RecorderCaptureOutlineTrace {
    struct Sample: Equatable {
        /// Conic gradient location: the clockwise angle from the centre, 0..<1.
        let angularLocation: Double
        /// Distance along the tube, as a fraction of its length, measured clockwise.
        let clockwiseFraction: Double
    }

    static let sampleCount = 72

    private var tracedPath: Path?
    private var tracedCenter: CGPoint?
    private var tracedSamples: [Sample] = []

    func samples(along path: Path, around center: CGPoint) -> [Sample] {
        if path == tracedPath, center == tracedCenter { return tracedSamples }
        tracedPath = path
        tracedCenter = center
        tracedSamples = Self.trace(path, around: center)
        return tracedSamples
    }

    /// Returns stops sorted by angle, plus matching seam stops at 0 and 1 so the
    /// gradient joins without a visible break. Recorder card shapes are star-shaped
    /// around their centre, so angle and distance advance together. — Claude Opus 5.5
    static func trace(_ path: Path, around center: CGPoint) -> [Sample] {
        var points: [(fraction: Double, location: Double)] = []
        points.reserveCapacity(sampleCount)
        for index in 1...sampleCount {
            let fraction = Double(index) / Double(sampleCount)
            guard let point = path.trimmedPath(from: 0, to: fraction).currentPoint else { continue }
            let turn = atan2(Double(point.y - center.y), Double(point.x - center.x)) / (2 * Double.pi)
            points.append((fraction.truncatingRemainder(dividingBy: 1), turn < 0 ? turn + 1 : turn))
        }
        guard points.count >= 3 else { return [] }

        // In SwiftUI's y-down space the angle grows clockwise. Normalise both path
        // directions so colour always flows clockwise on screen.
        var winding = 0.0
        for index in points.indices {
            let next = points[(index + 1) % points.count]
            winding += wrapped(next.location - points[index].location)
        }
        let isClockwise = winding >= 0

        var samples = points.map { point in
            Sample(
                angularLocation: point.location,
                clockwiseFraction: isClockwise ? point.fraction : 1 - point.fraction
            )
        }
        samples.sort { $0.angularLocation < $1.angularLocation }

        guard let first = samples.first, let last = samples.last else { return [] }
        let gap = (1 - last.angularLocation) + first.angularLocation
        let weight = gap > 0 ? (1 - last.angularLocation) / gap : 0
        let seam = last.clockwiseFraction
            + wrapped(first.clockwiseFraction - last.clockwiseFraction) * weight
        return [Sample(angularLocation: 0, clockwiseFraction: seam)]
            + samples
            + [Sample(angularLocation: 1, clockwiseFraction: seam)]
    }

    /// The shortest signed difference between two cyclic fractions. — Claude Opus 5.5
    static func wrapped(_ delta: Double) -> Double {
        delta - delta.rounded()
    }
}
