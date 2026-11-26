/// Ethan's "charging up a chained together attack": typing and newly recognised
/// speech feed the same visual momentum. This is a session-owned value, never an
/// audio detector or a ticking publisher. Mirrored outlines evaluate its integrated
/// travel on their existing clock. Pauses let charge ease away without a timer.
/// — GPT-6.1 Sol
import Foundation

struct RecorderOutlineActivity: Equatable {
    private(set) var hasTextActivity = false
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
        hasTextActivity = true
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
        let held = min(elapsed, Self.brakingDelay)
        let linear = Self.linearGain * charge
        let quadratic = Self.quadraticGain * charge * charge
        let target = Self.idleSpeed + linear + quadratic
        let difference = anchorSpeed - target
        let response = -expm1(-Self.responseRate * held)
        let speed = anchorSpeed - difference * response
        let travel = target * held + difference * response / Self.responseRate
        guard elapsed > held else { return (speed, travel) }

        // Ethan wants a short typing debounce, then coasting rather than a stop.
        // Brake the actual visible speed directly: a decaying target could still
        // accelerate after the last key. Retain separate charge for a resumed
        // chain, and integrate travel so braking never jumps the rainbow's colour.
        // This is visual motion only, not a keyboard/capture wait. — GPT-6.1 Sol
        let quiet = elapsed - held
        let momentum = speed - Self.idleSpeed
        return (
            Self.idleSpeed + momentum * exp(-Self.brakingRate * quiet),
            travel + Self.idleSpeed * quiet
                + momentum * Self.decayIntegral(Self.brakingRate, quiet)
        )
    }

    private static func decayIntegral(_ rate: Double, _ seconds: Double) -> Double {
        -expm1(-rate * seconds) / rate
    }

    private func remainingCharge(at date: Date) -> Double {
        let elapsed = max(0, date.timeIntervalSince(anchor) - Self.chargeRetentionInterval)
        return charge * exp(-Self.decayRate * elapsed)
    }

    static let idleSpeed = 0.35
    // Fifteen percent gentler than the first charge tuning, not a speed cap.
    // This changes visual momentum only; input/capture timing is untouched. — GPT-6.1 Sol
    private static let linearGain = 0.034
    private static let quadraticGain = 0.000765
    // Keep the existing half-second build-up. Ethan still found the matched-rate
    // coast too fast: exponential braking discarded 81% of the extra speed in
    // the first second after typing stopped. Let that momentum fade over a longer
    // tail (about 53% remains at one second), without delaying the start of braking.
    // Keep the prior 800 ms chaining allowance independent of that visual trigger:
    // slower continuous typing must not lose charge merely because braking starts.
    // Found and fixed by GPT-6.1 Sol.
    // Stored charge then fades more slowly, leaving a chance to resume the chain.
    // No timer, input wait or extra publisher is involved. — GPT-6.1 Sol
    private static let responseRate = 2.0
    private static let brakingRate = responseRate * 0.4
    private static let brakingDelay = 0.2
    private static let chargeRetentionInterval = 0.8
    // Charge drives a quadratic speed target. Retain the existing half-rate relation
    // explicitly, so a longer coast cannot leave resumed input chasing a target
    // below its visible momentum. Found and fixed by GPT-6.1 Sol.
    private static let decayRate = brakingRate / 2
    // One paste/model catch-up is a burst, not thousands of physical keystrokes.
    // Continuous input can still accumulate unlimited charge and speed. — GPT-6.1 Sol
    private static let maximumBurst = 32
}
