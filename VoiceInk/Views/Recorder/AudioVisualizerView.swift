// Draws microphone history and the recorder's idle/processing indicators in one
// stable control-row slot. Active bars use measured audio, not a clock. — GPT-6.1 Sol
import SwiftUI

/// The recorder's live microphone waveform: one bar per 100 ms of recently captured
/// audio, newest at the right, sliding left as more audio arrives.
///
/// Found by Ethan. Fixed by Claude Opus 5.5. Ethan said the old bars weren't
/// "representative of what I'm actually saying … just like a random animation". Every
/// bar shared one smoothed, boosted level multiplied by a clock-driven sine ripple and a
/// centre bump, so the shape came from the clock rather than his voice. Each bar
/// now shows one measured slice of `AudioMeter`, and drawing is a pure function of that
/// value: no clock, no randomness, no implicit animation. Silence draws flat dim dots,
/// and no captured audio means no movement. Reduce Motion steps whole bars instead of
/// sliding. The 73 × 28 pt footprint is unchanged. — Claude Opus 5.5
struct AudioVisualizer: View {
    let audioMeter: AudioMeter
    let color: Color
    let isActive: Bool
    /// Lets hosted renders exercise the Reduce Motion branch without changing the user's
    /// system setting, as RecorderCaptureOutline does. Real panels leave it nil.
    /// — Claude Opus 5.5
    let reduceMotionForPreview: Bool?
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    init(audioMeter: AudioMeter, color: Color, isActive: Bool, reduceMotionForPreview: Bool? = nil) {
        self.audioMeter = audioMeter
        self.color = color
        self.isActive = isActive
        self.reduceMotionForPreview = reduceMotionForPreview
    }

    var body: some View {
        // Recorder publishes at most one meter per 33 ms tick, observed only by this small
        // status subtree. Never give the waveform its own timeline or animation clock: an
        // independent 60 Hz waveform clock plus broad card invalidation caused verified
        // recorder lag (LEARNINGS, 2026-07-31). One Canvas also replaces fifteen bar views
        // that were re-diffed on every tick of every mirrored panel. — Claude Opus 5.5
        let bars = AudioVisualizerLayout.bars(
            for: isActive ? audioMeter : .silent,
            slidesWithCapturedAudio: !(reduceMotionForPreview ?? systemReduceMotion)
        )
        Canvas { context, size in
            context.clip(to: Path(CGRect(origin: .zero, size: size)))
            for bar in bars {
                context.fill(
                    Path(roundedRect: bar.frame, cornerRadius: AudioVisualizerLayout.barWidth / 2),
                    with: .color(color.opacity(bar.opacity))
                )
            }
        }
        .frame(width: AudioVisualizerLayout.width, height: AudioVisualizerLayout.height)
        .accessibilityHidden(true)
    }
}

/// Bar geometry for `AudioVisualizer`. It is a pure function so tests can prove the
/// drawing depends only on the measured meter. It keeps the previous footprint (15 bars,
/// 3 pt wide with 2 pt gaps, at most 28 pt tall), so the Mini and Notch rows, the
/// processing spinner's 28 pt slot and the nearby controls stay where they were.
/// — Claude Opus 5.5
enum AudioVisualizerLayout {
    struct Bar: Equatable {
        let frame: CGRect
        let opacity: Double
    }

    /// Bars ordered left to right, oldest first. The newest bar is the slice still being
    /// captured. It sits at the right edge so new sound shows on the next tick, and it
    /// grows as louder audio arrives inside its slice. While sliding, the whole strip
    /// moves left by the captured fraction of that slice, so finishing a slice continues
    /// the motion instead of jumping. Reduce Motion keeps every bar on a whole slot and
    /// steps once per finished slice. — Claude Opus 5.5
    static func bars(for meter: AudioMeter, slidesWithCapturedAudio: Bool) -> [Bar] {
        let visibleLevels = Array(meter.levels.suffix(barCount + 1))
        // Pad a short (malformed) meter with silence so every slot still reads as quiet.
        let levels = Array(repeating: Float(0), count: barCount + 1 - visibleLevels.count) + visibleLevels
        let slide = slidesWithCapturedAudio ? CGFloat(unitInterval(meter.currentSliceProgress)) : 0

        var bars: [Bar] = []
        bars.reserveCapacity(levels.count)
        for (age, rawLevel) in levels.reversed().enumerated() {
            let x = width - barWidth - (CGFloat(age) + slide) * barPitch
            // Older slices have slid fully past the left edge.
            guard x + barWidth > 0 else { break }
            let level = CGFloat(unitInterval(Double(rawLevel)))
            let barHeight = minimumBarHeight + level * (height - minimumBarHeight)
            // Louder bars are brighter as well as taller, so silent dots recede. The oldest
            // bars fade into the left edge to show that time runs left to right.
            let loudness = quietOpacity + (loudOpacity - quietOpacity) * Double(level)
            let pastFade = min(1, max(minimumPastFade, Double((x + barWidth / 2) / pastFadeWidth)))
            bars.append(Bar(
                frame: CGRect(x: x, y: (height - barHeight) / 2, width: barWidth, height: barHeight),
                opacity: loudness * pastFade
            ))
        }
        return Array(bars.reversed())
    }

    static let barCount = MicrophoneLevelHistory.completedSliceCount
    static let barWidth: CGFloat = 3
    static let barSpacing: CGFloat = 2
    /// A silent slice is a small dot, not an empty gap, so the waveform still reads as
    /// listening. — Claude Opus 5.5
    static let minimumBarHeight: CGFloat = 4
    static let height: CGFloat = 28
    static var barPitch: CGFloat { barWidth + barSpacing }
    static var width: CGFloat { CGFloat(barCount) * barPitch - barSpacing }

    static let quietOpacity = 0.4
    static let loudOpacity = 0.95
    /// The left three slots fade into the past. — Claude Opus 5.5
    static var pastFadeWidth: CGFloat { barPitch * 3 }
    static let minimumPastFade = 0.2

    /// Clamps to 0...1 and treats a non-finite value as silence. — Claude Opus 5.5
    private static func unitInterval(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : 0
    }
}

// Flat bars shown when the recorder is idle (no audio input)
struct StaticVisualizer: View {
    private let barCount = 15
    private let barWidth: CGFloat = 3
    private let barHeight: CGFloat = 4
    private let barSpacing: CGFloat = 2
    let color: Color

    var body: some View {
        HStack(spacing: barSpacing) {
            ForEach(0..<barCount, id: \.self) { _ in
                RoundedRectangle(cornerRadius: barWidth / 2)
                    .fill(color.opacity(0.5))
                    .frame(width: barWidth, height: barHeight)
            }
        }
    }
}

// MARK: - Processing Status Display

struct ProcessingStatusDisplay: View {
    enum Mode {
        case transcribing
        case enhancing
    }

    let mode: Mode
    let color: Color

    private var label: LocalizedStringKey {
        switch mode {
        case .transcribing: return "Transcribing"
        case .enhancing:    return "Enhancing"
        }
    }

    private var animationSpeed: Double {
        switch mode {
        case .transcribing: return 0.18
        case .enhancing:    return 0.22
        }
    }

    var body: some View {
        VStack(spacing: 4) {
            Text(label)
                .foregroundColor(color)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.5)

            ProgressAnimation(color: color, animationSpeed: animationSpeed)
        }
        .frame(height: 28) // matches AudioVisualizer maxHeight to prevent layout shift
    }
}
