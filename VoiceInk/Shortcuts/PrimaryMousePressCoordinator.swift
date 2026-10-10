import Foundation
import CoreFoundation

/// Orders entry into the existing gesture reducer without waiting for audio
/// startup/finalization. MainActor tasks may suspend independently after entry.
@MainActor
final class PrimaryMouseDecisionBarrier {
    private var entered = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if entered { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        guard !entered else { return }
        entered = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

/// A deliberately closed Karabiner protocol, not a generic automation endpoint.
/// Keyboard Primary still uses its existing balanced modifier shortcut.
struct PrimaryMouseCommand: Equatable, Sendable {
    enum Source: String, CaseIterable, Sendable { case corsair, razer }
    enum Phase: String, Sendable { case down, up }
    let source: Source
    let phase: Phase

    static let maximumPayloadBytes = 256

    static func decode(_ data: Data) -> Self? {
        guard !data.isEmpty, data.count <= maximumPayloadBytes,
              let object = try? JSONSerialization.jsonObject(with: data),
              let fields = object as? [String: Any],
              Set(fields.keys) == ["version", "action", "source", "phase"],
              let version = fields["version"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(), version == 1,
              fields["action"] as? String == "primaryRecordingMouse",
              let sourceName = fields["source"] as? String,
              let source = Source(rawValue: sourceName),
              let phaseName = fields["phase"] as? String,
              let phase = Phase(rawValue: phaseName) else { return nil }
        return Self(source: source, phase: phase)
    }
}

/// Physical edges select *when* to contribute one existing Primary gesture; they
/// never reinterpret stop, clipboard-only, pause, Next, or destination ownership.
struct PrimaryMousePressCoordinator {
    enum Context: Equatable {
        case idle
        // startID survives the synchronous reservation -> starting -> recording
        // handoff. A release must never act on a different recording's identity.
        case capture(UUID)
        case pending(UUID)
        case unavailable
    }

    enum Decision: String {
        case startOnDown
        case primaryOnRelease
        case armed
        case consumedStartRelease
        case coalescedStartDown
        case ignored
    }

    private struct Cycle {
        let context: Context
        let downTime: TimeInterval
        let startedOnDown: Bool
        let isStartAnchor: Bool
    }
    private var cycles: [PrimaryMouseCommand.Source: Cycle] = [:]
    private var lastEventTime: TimeInterval?
    private let startCompanionInterval: TimeInterval
    // A lost release must not turn an arbitrarily old hold into a new action.
    // This does not delay any accepted edge or expire a user's active recording.
    static let maximumCycleDuration: TimeInterval = 60

    init(startCompanionInterval: TimeInterval = 0.09) {
        self.startCompanionInterval = max(0, min(startCompanionInterval, 0.09))
    }

    mutating func reset() {
        cycles.removeAll(keepingCapacity: true)
        lastEventTime = nil
    }

    mutating func receive(
        _ command: PrimaryMouseCommand,
        eventTime: TimeInterval,
        context: Context
    ) -> Decision {
        guard eventTime.isFinite,
              lastEventTime.map({ eventTime >= $0 }) ?? true else { return .ignored }
        lastEventTime = eventTime
        if let cycle = cycles[command.source],
           eventTime - cycle.downTime > Self.maximumCycleDuration {
            cycles.removeValue(forKey: command.source)
        }
        switch command.phase {
        case .down:
            guard cycles[command.source] == nil else { return .ignored }
            let starts = context == .idle
            // Two physical controls pressed together can remain held long after
            // Start's down. Anchor duplicate protection on that accepted down,
            // not their later ups, or the second up would unexpectedly Stop.
            // A coalesced companion never extends the accepted anchor's window.
            let companion = cycles.values.contains {
                $0.isStartAnchor && eventTime - $0.downTime < startCompanionInterval
            }
            cycles[command.source] = Cycle(
                context: context, downTime: eventTime,
                startedOnDown: starts || companion, isStartAnchor: starts && !companion
            )
            if companion { return .coalescedStartDown }
            return starts ? .startOnDown : .armed
        case .up:
            guard let cycle = cycles.removeValue(forKey: command.source) else {
                return .ignored
            }
            // This is the *same* press that started capture, including when its
            // release beats microphone startup. It is never Stop or click two.
            if cycle.startedOnDown { return .consumedStartRelease }
            guard context == cycle.context else { return .ignored }
            switch context {
            case .capture, .pending: return .primaryOnRelease
            case .idle, .unavailable: return .ignored
            }
        }
    }
}
