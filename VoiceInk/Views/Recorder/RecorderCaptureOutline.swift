// Ethan's "rainbow thing": a thin, sharp rainbow border on every mirrored
// Mini and Notch recorder card. His 2026-11-24 refinement explicitly removes
// blur and colour bleeding into the black panel. MiniRecorderView and NotchRecorderView
// draw it from `RecorderStateProvider.showsRecordingActivityOutline`; Settings ->
// Interface -> Recording Outline turns it off. — GPT-6.1 Sol
import SwiftUI

/// One sharp stroke follows the recorder's silhouette during capture and transcription.
/// Colour still flows evenly around the border; there is no bloom, pale core,
/// opacity flicker or interior shading. Reduce Motion holds the colours still.
/// An accepted highlight or screenshot recolours the same stroke for one quick lap
/// (`RecorderContextSweep`); it never changes its width, alignment or phase. — Claude Opus 5.5
///
/// Callers place it in a `.background` above the card fill and beneath content, and
/// the card's own clip bounds it, so it changes no geometry, hit target, drag
/// surface, scroll view or keyboard focus. This is recording activity only. It never
/// marks a saved destination, a Next route or the current-focus icon.
/// Original design by Claude Opus 5.5; border-only refinement by GPT-6.1 Sol.
/// — GPT-6.1 Sol
struct RecorderCaptureOutline<OutlineShape: Shape>: View, Animatable {
    var shape: OutlineShape
    /// Formerly `topEdgeFade`: the Notch omits its closing top segment,
    /// without an opacity gradient into the black surface. Mini stays a closed ring. — GPT-6.1 Sol
    var omitsTopEdge = false
    /// The session's latest accepted highlight/screenshot. It is a plain value from
    /// the card, so this leaf still never observes the session. The lap is derived
    /// from this leaf's existing clock and simply stops being drawn when it ends.
    /// — Claude Opus 5.5
    var acceptancePulse: RecorderContextAcceptancePulse? = nil
    /// Transcription reverses with the existing input momentum, then accelerates
    /// on the same leaf clock; the real capture tail keeps recording motion. — GPT-6.1 Sol
    var isProcessing = false
    var processingStartedAt: Date? = nil
    var activity: RecorderOutlineActivity? = nil

    // macOS exposes Reduce Motion as a read-only environment value. Hosted
    // appearance previews can exercise its static branch without changing the
    // user's system accessibility preference; real panels leave this nil.
    // Found and fixed by GPT-6.1 Sol.
    var reduceMotionForPreview: Bool? = nil
    /// Native image tests supply exact frame times: two arbitrary wall-clock
    /// samples may legitimately alias at Ethan's uncapped loading speeds, and
    /// an occluded test window need not receive animation ticks. Real cards leave
    /// this nil and use the existing TimelineView date. — GPT-6.1 Sol
    var frameDateForPreview: Date? = nil
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { reduceMotionForPreview ?? systemReduceMotion }
    @Environment(\.displayScale) private var displayScale
    @State private var trace = RecorderCaptureOutlineTrace()
    /// Reduce Motion pauses the clock, so its still acknowledgement is held by one
    /// bounded task instead. — Claude Opus 5.5
    @State private var stillAcknowledgement: RecorderContextAcceptancePulse? = nil

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
        // never observes the session, the audio meter or the transcript. — Claude Opus 5.5
        TimelineView(.animation(
            minimumInterval: RecorderCaptureOutlineStyle.frameInterval,
            paused: reduceMotion
        )) { timeline in
            let frameDate = frameDateForPreview ?? timeline.date
            let phase = reduceMotion ? 0 : RecorderCaptureOutlineStyle.flowPhase(at: frameDate, isProcessing: isProcessing, processingStartedAt: processingStartedAt, activity: activity)
            // The lap reads the same wall-clock frame as the rainbow, so mirrored
            // panels match, and it never shifts the rainbow's phase. — Claude Opus 5.5
            let acknowledgement = reduceMotion
                ? stillAcknowledgement.map { RecorderContextSweep.Acknowledgement(kind: $0.kind, form: .still) }
                : RecorderContextSweep.acknowledgement(for: acceptancePulse, at: frameDate)
            // Follow the live charged colour band; if loading begins mid-lap,
            // its mask keeps that live frame while the rainbow beneath reverses.
            // With no pulse, no second phase calculation is needed.
            // Found and fixed by GPT-6.1 Sol.
            let acknowledgementPhase = !reduceMotion && acknowledgement != nil
                ? (isProcessing ? RecorderCaptureOutlineStyle.flowPhase(at: frameDate, activity: activity) : phase)
                : 0
            GeometryReader { geometry in
                let frame = geometry.frame(in: .global)
                let pixels = RecorderCaptureOutlinePixels(
                    localSize: geometry.size, frame: frame, displayScale: displayScale)
                Canvas { context, size in
                    drawBorder(in: context, size: size, phase: phase,
                               acknowledgementPhase: acknowledgementPhase,
                               acknowledgement: acknowledgement, pixels: pixels)
                }
                .frame(width: pixels.bounds.width, height: pixels.bounds.height)
                .offset(x: pixels.bounds.minX, y: pixels.bounds.minY)
            }
        }
        // A newer pulse or the outline's removal cancels this task, so no hold can
        // outlive its pulse or clear a newer one. — Claude Opus 5.5
        .task(id: acceptancePulse?.id) { await holdStillAcknowledgement() }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Reduce Motion's acknowledgement: the whole border takes the context colour
    /// for `RecorderContextSweep.stillDuration`, without movement or fade, then
    /// returns to the still rainbow. With motion this returns at once and the lap
    /// runs on the leaf's own clock. — Claude Opus 5.5
    private func holdStillAcknowledgement() async {
        guard reduceMotion, let pulse = acceptancePulse,
              let remaining = RecorderContextSweep.stillRemaining(of: pulse, at: Date()) else {
            if stillAcknowledgement != nil { stillAcknowledgement = nil }
            return
        }
        stillAcknowledgement = pulse
        try? await Task.sleep(for: .seconds(remaining))
        guard !Task.isCancelled, stillAcknowledgement?.id == pulse.id else { return }
        stillAcknowledgement = nil
    }

    // Former `drawNeonTube`: one stroke replaces its bloom and pale core. — GPT-6.1 Sol
    private func drawBorder(in context: GraphicsContext, size: CGSize, phase: Double,
                            acknowledgementPhase: Double,
                            acknowledgement: RecorderContextSweep.Acknowledgement?,
                            pixels: RecorderCaptureOutlinePixels) {
        let style = RecorderCaptureOutlineStyle.self
        let bounds = CGRect(origin: .zero, size: size)
        guard bounds.width > style.tubeInset * 4, bounds.height > style.tubeInset * 4 else { return }

        // The same shape in a slightly smaller rect keeps the tube parallel to the
        // card edge, including the Notch flares, without needing an insettable shape.
        let insetPath = shape.path(in: bounds.insetBy(dx: pixels.width / 2, dy: pixels.width / 2))
        let tubePath = pixels.aligned(insetPath)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let samples = trace.samples(along: tubePath, around: center)
        guard !samples.isEmpty else { return }

        // Only while an acknowledgement shows: the transcript colour as this panel
        // draws it, recoloring the same stops along the same single stroke.
        let paint = acknowledgement.map {
            RecorderContextSweepPaint(
                tint: RecorderContextSweep.components(of: $0.kind.color, in: context.environment),
                form: $0.form)
        }
        let tube = GraphicsContext.Shading.conicGradient(
            Gradient(stops: samples.map { sample in
                let position = sample.clockwiseFraction - phase
                return Gradient.Stop(
                    // The pulse mask and underlying rainbow can have different
                    // motion. A zero-strength or uncovered pulse must return the
                    // actual rainbow, never reset it to the mask's old clock.
                    // Found and fixed by GPT-6.1 Sol.
                    color: paint?.color(at: sample.clockwiseFraction - acknowledgementPhase,
                                        rainbowPosition: position)
                        ?? RecorderNeonSpectrum.color(at: position),
                    location: sample.angularLocation
                )
            }),
            center: center
        )
        let strokePath = omitsTopEdge ? pixels.aligned(insetPath, omittingTopEdge: true) : tubePath
        context.stroke(strokePath, with: tube, lineWidth: pixels.width)
    }
}

/// Fits the thin stroke to whole backing pixels after the HUD's scaleEffect.
/// A 1pt line at 85% can otherwise split across two faint side columns while a
/// horizontal edge lands on one solid row. Geometry's global frame includes that
/// transform; displayScale accounts for Retina. The caller still owns its clip,
/// so an extra antialiased silhouette mask cannot dim the edge a second time.
/// Found by Ethan. Fixed by GPT-6.1 Sol.
struct RecorderCaptureOutlinePixels {
    let width: CGFloat
    let bounds: CGRect
    private let scale: CGFloat

    init(localSize: CGSize, frame: CGRect, displayScale: CGFloat) {
        let hudScale = localSize.width > 0 ? frame.width / localSize.width : 1
        scale = max(0.01, hudScale * displayScale)
        width = max(1, (RecorderCaptureOutlineStyle.tubeWidth * scale).rounded()) / scale
        let origin = CGPoint(x: frame.minX * displayScale, y: frame.minY * displayScale)
        let minimum = CGPoint(x: origin.x.rounded(.up), y: origin.y.rounded(.up))
        let maximum = CGPoint(x: (origin.x + localSize.width * scale).rounded(.down),
                              y: (origin.y + localSize.height * scale).rounded(.down))
        bounds = CGRect(x: (minimum.x - origin.x) / scale, y: (minimum.y - origin.y) / scale,
                        width: max(0, maximum.x - minimum.x) / scale,
                        height: max(0, maximum.y - minimum.y) / scale)
    }

    func aligned(_ path: Path, omittingTopEdge: Bool = false) -> Path {
        let halfPixels = width * scale / 2
        func point(_ value: CGPoint) -> CGPoint {
            CGPoint(
                x: ((value.x * scale - halfPixels).rounded() + halfPixels) / scale,
                y: ((value.y * scale - halfPixels).rounded() + halfPixels) / scale)
        }
        let top = path.boundingRect.minY
        var result = Path()
        path.forEach { element in
            switch element {
            case .move(let p): result.move(to: point(p))
            case .line(let p):
                // NotchShape closes its U with one explicit line back to the top.
                // Omit that segment rather than clipping its antialiased pixels,
                // which leaked a faint horizontal line after HUD resampling.
                // Found and fixed by GPT-6.1 Sol.
                if omittingTopEdge && abs(p.y - top) < 0.0001 {
                    result.move(to: point(p))
                } else {
                    result.addLine(to: point(p))
                }
            case .quadCurve(let p, let c): result.addQuadCurve(to: point(p), control: point(c))
            case .curve(let p, let c1, let c2):
                result.addCurve(to: point(p), control1: point(c1), control2: point(c2))
            case .closeSubpath: result.closeSubpath()
            }
        }
        return result
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

    /// Ethan explicitly rejected a top speed: both speed and its rate of change
    /// keep growing. Cubic travel gives quadratic speed and increasing acceleration,
    /// rather than small constant speed increments that become hard to notice.
    /// Pure arithmetic on the existing30Hz leaf; it never requests more frames.
    static let initialProcessingSpeed = 2.0
    static let processingAccelerationGain = 1.5

    static func processingSpeed(elapsed: TimeInterval) -> Double {
        let seconds = max(0, elapsed)
        return initialProcessingSpeed + processingAccelerationGain * seconds * seconds
    }

    static func processingTravel(elapsed: TimeInterval) -> Double {
        let seconds = max(0, elapsed)
        return (initialProcessingSpeed * seconds
            + processingAccelerationGain / 3 * seconds * seconds * seconds) / lapDuration
    }

    /// Phase uses the session's one timestamp, never a per-window start/reset.
    /// Missing timing (legacy/preview providers) retains the existing2x fallback.
    /// Live text charge supplies the colour at the processing boundary, so reversing
    /// never jumps to a different rainbow. — GPT-6.1 Sol
    static func flowPhase(at date: Date, isProcessing: Bool = false, processingStartedAt: Date? = nil,
                          activity: RecorderOutlineActivity? = nil) -> Double {
        guard isProcessing else {
            return activity?.phase(at: date)
                ?? (date.timeIntervalSinceReferenceDate / lapDuration).truncatingRemainder(dividingBy: 1)
        }
        guard let processingStartedAt else {
            return (-2 * date.timeIntervalSinceReferenceDate / lapDuration).truncatingRemainder(dividingBy: 1)
        }
        // Start from the exact recording colour at the boundary, then reverse.
        let origin = activity?.phase(at: processingStartedAt)
            ?? processingStartedAt.timeIntervalSinceReferenceDate / lapDuration
        // Keep accumulated input speed instead of suddenly dropping to2x at Stop.
        // The original uncapped loading acceleration still adds to that baseline.
        // Found and fixed by GPT-6.1 Sol.
        let carriedSpeed = max(initialProcessingSpeed, activity?.speed(at: processingStartedAt) ?? initialProcessingSpeed)
        let elapsed = max(0, date.timeIntervalSince(processingStartedAt))
        return (origin - processingTravel(elapsed: elapsed)
            - (carriedSpeed - initialProcessingSpeed) * elapsed / lapDuration)
            .truncatingRemainder(dividingBy: 1)
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

    /// The colour at a cyclic position, where 0 and 1 are the same point. — GPT-6.1 Sol
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
        /// Conic gradient location: the clockwise angle from the centre, 0..<1. — Claude Opus 5.5
        let angularLocation: Double
        /// Distance along the tube, as a fraction of its length, measured clockwise. — Claude Opus 5.5
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
