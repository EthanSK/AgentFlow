// The recorder HUD's microphone meter: what the waveform draws and how it is built
// from measured sound. CoreAudioRecorder sums captured energy on the audio thread
// (`MicrophoneLevelAccumulator`); Recorder's 33 ms main-queue tick drains it into the
// one bounded `MicrophoneLevelHistory` and publishes an `AudioMeter` snapshot; every
// mirrored Mini/Notch `AudioVisualizer` draws that snapshot. It is a separate file
// because all three layers share it and its pure types are the unit-test seam.
// Microphone loudness only: it never proves that words were recognised. — Claude Opus 5.5
import Foundation

/// What every mirrored recorder waveform draws: the loudness of the most recently
/// captured audio, oldest slice first. Only `MicrophoneLevelHistory` builds it, from
/// measured microphone energy; nothing in it is animated, boosted or invented.
/// — Claude Opus 5.5
struct AudioMeter: Equatable, Sendable {
    /// Display levels in 0...1, oldest first: `MicrophoneLevelHistory.completedSliceCount`
    /// finished slices, then the slice still being captured. — Claude Opus 5.5
    let levels: [Float]
    /// How much of the newest slice has been captured, in 0...1. The waveform slides by
    /// this fraction of a bar, so its motion follows captured audio time, not a clock.
    /// — Claude Opus 5.5
    let currentSliceProgress: Double

    /// A fresh recording, a quiet room, Pause and microphone-off typing all draw this
    /// flat state. Silence carries no slide progress, so consecutive silent ticks compare
    /// equal and Recorder skips republishing identical pixels to every panel.
    /// — Claude Opus 5.5
    static let silent = AudioMeter(
        levels: Array(repeating: 0, count: MicrophoneLevelHistory.completedSliceCount + 1),
        currentSliceProgress: 0
    )

    var isSilent: Bool { levels.allSatisfy { $0 == 0 } }
}

/// The one bounded record of recent microphone loudness that Recorder keeps for all
/// mirrored panels. Captured audio is cut into fixed slices of audio time; each slice
/// keeps the loudest window measured inside it. Memory stays at `completedSliceCount`
/// slices plus the one being filled, however long the recording runs. Main actor only
/// (Recorder's meter tick). — Claude Opus 5.5
struct MicrophoneLevelHistory: Equatable, Sendable {
    /// One slice per visible waveform bar: 1.5 seconds of recent sound. — Claude Opus 5.5
    static let completedSliceCount = 15
    /// 100 ms keeps syllables (roughly 150–300 ms) visibly apart while 1.5 seconds still
    /// shows the last few words. One-tick (33 ms) slices scrolled too fast to read, and
    /// longer slices merged neighbouring words into one block. — Claude Opus 5.5
    static let sliceDuration: TimeInterval = 0.1

    private(set) var completedLevels = Array(
        repeating: Float(0), count: MicrophoneLevelHistory.completedSliceCount
    )
    private(set) var currentLevel: Float = 0
    private(set) var currentDuration: TimeInterval = 0

    /// Adds one measured window in capture order. Returns false when the window holds no
    /// audio, because no buffer arrived since the last tick (a stalled device or a closing
    /// capture). The caller then keeps the previous frame instead of inventing motion.
    /// — Claude Opus 5.5
    @discardableResult
    mutating func append(_ window: MicrophoneLevelWindow) -> Bool {
        guard window.duration.isFinite, window.duration > 0 else { return false }
        let level = MicrophoneLevelScale.displayLevel(forDecibels: window.rmsDecibels)
        // A long window (the first read after a slow hardware start, or a busy main
        // thread) spans several slices. Its single measured level fills each of them:
        // detail finer than the window was never measured, so none is invented. Anything
        // older than one full history would scroll away anyway, which also bounds this
        // loop for an arbitrarily long window. — Claude Opus 5.5
        var remaining = min(window.duration, Self.sliceDuration * Double(Self.completedSliceCount + 1))
        while remaining > Self.durationTolerance {
            let used = min(remaining, Self.sliceDuration - currentDuration)
            currentLevel = max(currentLevel, level)
            currentDuration += used
            remaining -= used
            if currentDuration >= Self.sliceDuration - Self.durationTolerance {
                completedLevels.removeFirst()
                completedLevels.append(currentLevel)
                currentLevel = 0
                currentDuration = 0
            }
        }
        return true
    }

    /// The snapshot every panel draws. — Claude Opus 5.5
    var meter: AudioMeter {
        let levels = completedLevels + [currentLevel]
        guard levels.contains(where: { $0 > 0 }) else { return .silent }
        return AudioMeter(
            levels: levels,
            currentSliceProgress: min(1, max(0, currentDuration / Self.sliceDuration))
        )
    }

    /// Absorbs floating-point drift when 33 ms windows are summed into 100 ms slices.
    /// — Claude Opus 5.5
    private static let durationTolerance: TimeInterval = 1e-9
}

/// Maps measured loudness to bar height, linearly in decibels, which is how hearing
/// judges loudness. Equal decibel steps give equal height steps. The scale is fixed on
/// purpose: an automatic gain or adaptive noise floor would draw the same voice at
/// different heights from moment to moment and could lift room noise into lively bars.
/// The old waveform's `pow(0.7)` boost over a −60 dBFS floor is what made quiet rooms
/// look busy. — Claude Opus 5.5
enum MicrophoneLevelScale {
    /// Quiet rooms usually measure −60 to −55 dBFS RMS at a sensible input gain, so they
    /// draw flat. Real but faint sound above this, such as a fan or typing, draws small.
    /// — Claude Opus 5.5
    static let silenceFloorDecibels: Float = -54
    /// Loud close speech. Louder input, including clipping, stays at full height.
    /// — Claude Opus 5.5
    static let fullScaleDecibels: Float = -12

    /// 0 at or below the silence floor, 1 at or above full scale. — Claude Opus 5.5
    static func displayLevel(forDecibels decibels: Float) -> Float {
        guard !decibels.isNaN else { return 0 }
        let fraction = (decibels - silenceFloorDecibels) / (fullScaleDecibels - silenceFloorDecibels)
        return min(1, max(0, fraction))
    }
}

/// Everything the microphone captured between two meter reads, as one energy
/// measurement. — Claude Opus 5.5
struct MicrophoneLevelWindow: Equatable, Sendable {
    /// Seconds of captured audio covered. Zero when no buffer arrived. — Claude Opus 5.5
    let duration: TimeInterval
    /// RMS over every captured frame in the window, in dBFS. — Claude Opus 5.5
    let rmsDecibels: Float

    static let empty = MicrophoneLevelWindow(
        duration: 0,
        rmsDecibels: MicrophoneLevelAccumulator.silenceDecibels
    )
}

/// Sums captured energy on the audio thread until the meter tick drains it.
///
/// Found by Ethan. Fixed by Claude Opus 5.5. The old meter kept only the newest buffer's
/// level. A 33 ms tick therefore saw about one 10 ms buffer in three and could miss a short
/// syllable completely. This holds three scalars under CoreAudioRecorder's existing
/// `meterLock`: no allocation, logging or dispatch on the real-time thread. — Claude Opus 5.5
struct MicrophoneLevelAccumulator: Sendable {
    /// Matches CoreAudioRecorder's reset meter value. — Claude Opus 5.5
    static let silenceDecibels: Float = -160

    private(set) var squareSum: Double = 0
    private(set) var frameCount = 0
    private(set) var duration: TimeInterval = 0

    /// Adds one captured buffer's summed squared samples, measured from the same dominant
    /// channel CoreAudioRecorder writes to the WAV. A malformed buffer adds neither energy
    /// nor time. — Claude Opus 5.5
    mutating func addBuffer(squareSum bufferSquareSum: Double, frameCount bufferFrameCount: Int, sampleRate: Double) {
        guard bufferFrameCount > 0, sampleRate > 0, bufferSquareSum.isFinite, bufferSquareSum >= 0 else { return }
        squareSum += bufferSquareSum
        frameCount += bufferFrameCount
        duration += Double(bufferFrameCount) / sampleRate
    }

    /// Energy-weighted RMS over every added frame. Uses the same −120 dBFS digital-silence
    /// limit as CoreAudioRecorder's per-buffer meter. — Claude Opus 5.5
    var window: MicrophoneLevelWindow {
        guard frameCount > 0 else { return .empty }
        let rms = (squareSum / Double(frameCount)).squareRoot()
        return MicrophoneLevelWindow(
            duration: duration,
            rmsDecibels: Float(20 * log10(max(rms, 0.000001)))
        )
    }
}
