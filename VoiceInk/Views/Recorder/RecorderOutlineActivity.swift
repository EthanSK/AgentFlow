/// Ethan's "charging up a chained together attack": typing and newly recognised
/// speech feed the same visual momentum. This is a session-owned value, never an
/// audio detector or a ticking publisher. Mirrored outlines evaluate its integrated
/// travel on their existing clock. Pauses let charge ease away without a timer.
/// — GPT-6.1 Sol
import Foundation

struct RecorderOutlineActivity: Equatable {
    private var anchor: Date
    private var anchorPhase: Double
    private var charge = 0.0

    init(at date: Date = Date()) {
        anchor = date
        anchorPhase = (date.timeIntervalSinceReferenceDate * Self.idleSpeed
            / RecorderCaptureOutlineStyle.lapDuration).truncatingRemainder(dividingBy: 1)
    }

    mutating func addText(units: Int, at date: Date) {
        guard units > 0 else { return }
        // Late timestamps never rewind the shared phase or resurrect older charge.
        let date = max(anchor, date)
        anchorPhase = phase(at: date)
        charge = remainingCharge(at: date) + Double(min(units, Self.maximumBurst))
        anchor = date
    }

    func speed(at date: Date) -> Double {
        let value = remainingCharge(at: date)
        return Self.idleSpeed + Self.linearGain * value + Self.quadraticGain * value * value
    }

    func phase(at date: Date) -> Double {
        let elapsed = max(0, date.timeIntervalSince(anchor))
        let held = min(elapsed, Self.chainInterval)
        let decaying = max(0, elapsed - held)
        let linear = Self.linearGain * charge
        let quadratic = Self.quadraticGain * charge * charge
        // Exact integral of the held, then exponentially decaying charge. No
        // frame-by-frame accumulation: phase stays continuous when input arrives,
        // independent of frame rate, window visibility and mirrored display count.
        let travel = Self.idleSpeed * elapsed + (linear + quadratic) * held
            + linear * -expm1(-Self.decayRate * decaying) / Self.decayRate
            + quadratic * -expm1(-2 * Self.decayRate * decaying) / (2 * Self.decayRate)
        return (anchorPhase + travel / RecorderCaptureOutlineStyle.lapDuration)
            .truncatingRemainder(dividingBy: 1)
    }

    private func remainingCharge(at date: Date) -> Double {
        let elapsed = max(0, date.timeIntervalSince(anchor) - Self.chainInterval)
        return charge * exp(-Self.decayRate * elapsed)
    }

    static let idleSpeed = 0.35
    private static let linearGain = 0.04
    private static let quadraticGain = 0.0009
    private static let chainInterval = 0.8
    private static let decayRate = 1.5
    // One paste/model catch-up is a burst, not thousands of physical keystrokes.
    // Continuous input can still accumulate unlimited charge and speed. — GPT-6.1 Sol
    private static let maximumBurst = 32
}
