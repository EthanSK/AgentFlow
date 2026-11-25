/// Ethan's "charging up a chained together attack": typing and newly recognised
/// speech feed the same visual momentum. This is a session-owned value, never an
/// audio detector or a ticking publisher. Mirrored outlines evaluate its integrated
/// travel on their existing clock. Pauses let charge ease away without a timer.
/// — GPT-6.1 Sol
import Foundation

struct RecorderOutlineActivity: Equatable {
    private var anchor: Date
    private var anchorPhase: Double
    private var anchorSpeed: Double
    private var charge = 0.0

    init(at date: Date = Date()) {
        anchor = date
        anchorSpeed = Self.idleSpeed
        anchorPhase = (date.timeIntervalSinceReferenceDate * Self.idleSpeed
            / RecorderCaptureOutlineStyle.lapDuration).truncatingRemainder(dividingBy: 1)
    }

    mutating func addText(units: Int, at date: Date) {
        guard units > 0 else { return }
        // Late timestamps never rewind the shared phase or resurrect older charge.
        let date = max(anchor, date)
        let current = motion(at: date)
        anchorPhase = (anchorPhase + current.travel / RecorderCaptureOutlineStyle.lapDuration)
            .truncatingRemainder(dividingBy: 1)
        anchorSpeed = current.speed
        charge = remainingCharge(at: date) + Double(min(units, Self.maximumBurst))
        anchor = date
    }

    func speed(at date: Date) -> Double {
        motion(at: date).speed
    }

    func phase(at date: Date) -> Double {
        (anchorPhase + motion(at: date).travel / RecorderCaptureOutlineStyle.lapDuration)
            .truncatingRemainder(dividingBy: 1)
    }

    // Ethan reported occasional fast starts followed by a sudden slowdown, then
    // requested only a small, gentler build-up. Text changes the target speed;
    // the visible speed eases toward it and never jumps at an input event. This
    // exact integral keeps the existing clock, including between mirrored frames.
    // Found and fixed by GPT-6.1 Sol. — GPT-6.1 Sol
    private func motion(at date: Date) -> (speed: Double, travel: Double) {
        let elapsed = max(0, date.timeIntervalSince(anchor))
        let held = min(elapsed, Self.chainInterval)
        let linear = Self.linearGain * charge
        let quadratic = Self.quadraticGain * charge * charge
        let target = Self.idleSpeed + linear + quadratic
        let difference = anchorSpeed - target
        let response = -expm1(-Self.responseRate * held)
        let speed = anchorSpeed - difference * response
        let travel = target * held + difference * response / Self.responseRate
        guard elapsed > held else { return (speed, travel) }

        // After the chaining interval, both charge terms decay as before. Solve
        // the same gentle speed response analytically through that quiet period.
        let quiet = elapsed - held
        let first = Self.responseRate * linear / (Self.responseRate - Self.decayRate)
        let second = Self.responseRate * quadratic / (Self.responseRate - 2 * Self.decayRate)
        let settling = speed - Self.idleSpeed - first - second
        return (
            Self.idleSpeed + first * exp(-Self.decayRate * quiet)
                + second * exp(-2 * Self.decayRate * quiet)
                + settling * exp(-Self.responseRate * quiet),
            travel + Self.idleSpeed * quiet
                + first * Self.decayIntegral(Self.decayRate, quiet)
                + second * Self.decayIntegral(2 * Self.decayRate, quiet)
                + settling * Self.decayIntegral(Self.responseRate, quiet)
        )
    }

    private static func decayIntegral(_ rate: Double, _ seconds: Double) -> Double {
        -expm1(-rate * seconds) / rate
    }

    private func remainingCharge(at date: Date) -> Double {
        let elapsed = max(0, date.timeIntervalSince(anchor) - Self.chainInterval)
        return charge * exp(-Self.decayRate * elapsed)
    }

    static let idleSpeed = 0.35
    // Fifteen percent gentler than the first charge tuning, not a speed cap.
    // This changes visual momentum only; input/capture timing is untouched. — GPT-6.1 Sol
    private static let linearGain = 0.034
    private static let quadraticGain = 0.000765
    // A half-second visual response; it never holds a keystroke or audio chunk.
    // The analytic decay solution needs this distinct from1.5 and3. — GPT-6.1 Sol
    private static let responseRate = 2.0
    private static let chainInterval = 0.8
    private static let decayRate = 1.5
    // One paste/model catch-up is a burst, not thousands of physical keystrokes.
    // Continuous input can still accumulate unlimited charge and speed. — GPT-6.1 Sol
    private static let maximumBurst = 32
}
