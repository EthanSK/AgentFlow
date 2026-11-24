// Flowing neon rainbow ring that marks live microphone capture on every mirrored
// Mini and Notch recorder card. Ethan asked for it on 2026-11-24 so he can tell at
// a glance that Agent Flow is recording. MiniRecorderView and NotchRecorderView
// draw it from `RecorderStateProvider.showsLiveCaptureOutline`; Settings ->
// Interface -> Recording Outline turns it off.
import SwiftUI

/// A neon tube drawn just inside a recorder card's own silhouette while that card's
/// microphone is live.
///
/// Design: a real neon sign rather than a thick multicolour border. A saturated
/// tube carries a hotter, paler core of the same hue, and its light bleeds a few
/// points into the dark glass. Colour advances along the tube at an even pace, so
/// a wide 1,100pt transcript card and a 40pt capsule both read as one continuous
/// tube. When capture starts or resumes the tube "strikes" with one brief flicker,
/// like a sign catching; Reduce Motion replaces that with a plain fade and holds the
/// colours still.
///
/// Callers place it in a `.background` above the card fill and beneath content, and
/// the card's own clip bounds it, so it changes no geometry, hit target, drag
/// surface, scroll view or keyboard focus. This is capture state only. It never
/// marks a saved destination, a Next route or the current-focus icon. — Claude Opus 5.5
struct RecorderCaptureOutline<OutlineShape: Shape>: View, Animatable {
    var shape: OutlineShape
    /// Points at the top to fade out. The Notch pill hangs from the display's top
    /// edge, so its tube fades into the bezel instead of running along the menu bar.
    /// The Mini card floats freely, so it keeps a closed ring. — Claude Opus 5.5
    var topEdgeFade: CGFloat = 0

    // macOS exposes Reduce Motion as a read-only environment value. Hosted
    // appearance previews can exercise its static branch without changing the
    // user's system accessibility preference; real panels leave this nil.
    var reduceMotionForPreview: Bool? = nil
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { reduceMotionForPreview ?? systemReduceMotion }
    @State private var trace = RecorderCaptureOutlineTrace()
    @State private var ignition: Double = 0
    @State private var ignitionTask: Task<Void, Never>?

    /// Forwards the card shape's own animation, so the tube follows the clip through
    /// compact/expanded corner and size springs instead of snapping ahead of it and
    /// being cut off at the corners. — Claude Opus 5.5
    var animatableData: AnimatablePair<OutlineShape.AnimatableData, CGFloat> {
        get { AnimatablePair(shape.animatableData, topEdgeFade) }
        set {
            shape.animatableData = newValue.first
            topEdgeFade = newValue.second
        }
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
                drawNeonTube(in: context, size: size, phase: phase)
            }
        }
        .opacity(ignition)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear(perform: ignite)
        .onDisappear {
            ignitionTask?.cancel()
            ignitionTask = nil
        }
    }

    /// Draws bloom, tube and core into one isolated layer clipped to the card, so the
    /// Notch top fade erases only the outline and never the card fill. — Claude Opus 5.5
    private func drawNeonTube(in context: GraphicsContext, size: CGSize, phase: Double) {
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
        let core = GraphicsContext.Shading.conicGradient(
            Gradient(stops: samples.map { sample in
                Gradient.Stop(
                    color: RecorderNeonSpectrum.color(
                        at: sample.clockwiseFraction - phase, whiteMix: style.coreWhiteMix
                    ),
                    location: sample.angularLocation
                )
            }),
            center: center
        )

        context.drawLayer { layer in
            layer.clip(to: cardPath)
            layer.drawLayer { bloom in
                bloom.opacity = style.bloomOpacity
                bloom.addFilter(.blur(radius: style.bloomBlurRadius))
                bloom.stroke(tubePath, with: tube, lineWidth: style.bloomWidth)
            }
            layer.stroke(tubePath, with: tube, lineWidth: style.tubeWidth)
            layer.stroke(tubePath, with: core, lineWidth: style.coreWidth)

            guard topEdgeFade > 0 else { return }
            layer.blendMode = .destinationOut
            layer.fill(
                Path(CGRect(x: 0, y: 0, width: size.width, height: topEdgeFade)),
                with: .linearGradient(
                    Gradient(colors: [.black, .black.opacity(0)]),
                    startPoint: .zero,
                    endPoint: CGPoint(x: 0, y: topEdgeFade)
                )
            )
        }
    }

    /// Lights the tube each time capture starts or resumes. The single dip is the
    /// signature "neon catching" beat and acknowledges live audio; it is presentation
    /// only and never delays capture or any recorder action. Reduce Motion gets a
    /// plain fade with no flicker. — Claude Opus 5.5
    private func ignite() {
        ignitionTask?.cancel()
        let shouldReduceMotion = reduceMotion

        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) { ignition = 0 }

        guard !shouldReduceMotion else {
            withAnimation(.easeOut(duration: 0.18)) { ignition = 1 }
            return
        }

        ignitionTask = Task { @MainActor in
            withAnimation(.easeOut(duration: 0.05)) { ignition = 0.9 }
            do { try await Task.sleep(nanoseconds: 70_000_000) } catch { return }
            withAnimation(.easeIn(duration: 0.04)) { ignition = 0.3 }
            do { try await Task.sleep(nanoseconds: 60_000_000) } catch { return }
            withAnimation(.easeOut(duration: 0.2)) { ignition = 1 }
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

/// Tube proportions and flow timing in recorder points, before the HUD size slider
/// scales the whole panel. The bloom stays within about 10pt of the edge, clear of
/// every control's padding, so text and buttons keep their existing contrast.
/// — Claude Opus 5.5
enum RecorderCaptureOutlineStyle {
    static let tubeInset: CGFloat = 1.6
    static let tubeWidth: CGFloat = 2.2
    static let coreWidth: CGFloat = 0.8
    static let coreWhiteMix: Double = 0.45
    static let bloomWidth: CGFloat = 7
    static let bloomBlurRadius: CGFloat = 5
    static let bloomOpacity: Double = 0.6
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

    /// The colour at a cyclic position, where 0 and 1 are the same point. `whiteMix`
    /// lifts the same hue toward white for the tube's hot core. — Claude Opus 5.5
    static func components(at position: Double, whiteMix: Double = 0) -> Components {
        let wrapped = position - position.rounded(.down)
        let scaled = wrapped * Double(anchors.count)
        let lowerIndex = min(Int(scaled), anchors.count - 1)
        let upperIndex = (lowerIndex + 1) % anchors.count
        let blend = scaled - Double(lowerIndex)
        let lower = anchors[lowerIndex]
        let upper = anchors[upperIndex]
        func channel(_ from: Double, _ to: Double) -> Double {
            let value = from + (to - from) * blend
            return value + (1 - value) * whiteMix
        }
        return Components(
            red: channel(lower.red, upper.red),
            green: channel(lower.green, upper.green),
            blue: channel(lower.blue, upper.blue)
        )
    }

    static func color(at position: Double, whiteMix: Double = 0) -> Color {
        let components = components(at: position, whiteMix: whiteMix)
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
