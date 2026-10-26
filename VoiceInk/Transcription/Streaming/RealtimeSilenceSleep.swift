import Foundation

// ═══════════════════════════════════════════════════════════════════════════════
// GPT Live silence sleep — network-stream omission only
// ═══════════════════════════════════════════════════════════════════════════════
//
// WHAT: while an ordinary recording keeps capturing, stop appending clearly quiet
// PCM to the open OpenAI `gpt-live-transcribe` socket, then resume immediately when
// local sound or this session's own activity returns. One socket stays open and the
// recording still ends with exactly one `input_audio_buffer.commit` at Stop.
//
// WHY: Ethan asked for long silent listening periods not to stream to OpenAI while
// Agent Flow keeps recording (2026-10-24). Streaming transcription is documented as
// billed by audio duration. Synthetic production-API probes on 2026-10-24 billed
// 21 s with sent silence versus 6 s with no appends; a five-minute no-append gap
// with boundary margins billed 8 s for 7.46 s sent and preserved both phrases.
// This proves those sessions, not every microphone, provider, or future idle limit.
//
// HARD BOUNDARIES (do not relax without new evidence and Ethan's approval):
//  • Network omission only. CoreAudioRecorder still writes every frame to the WAV
//    and forwards every frame to the realtime callback; this gate sits downstream in
//    StreamingTranscriptionService. Recovery, History, retranscription and the
//    completed-file fallback always have the complete audio.
//  • Not manual Pause. AUHAL keeps running, the waveform keeps moving, media and
//    the YouTube helper are untouched, and the session stays `.recording`.
//  • Never a commit or delivery boundary. The OpenAI provider accepts exactly one
//    final per recording (`yieldFinalOnce`), so committing at each silence would
//    silently drop every later item. Sleeping/waking never commits, pastes, sends
//    Return, or changes the Primary/Next destination.
//  • Not speaker identification. The classifier only asks "is this audio clearly
//    quiet?". Any audible sound — Ethan, a presenter, a singer, music, a keyboard —
//    keeps or wakes the stream. Uncertain audio fails open (it is sent).
//  • Intentional omission is accounted separately from real loss. Withheld quiet
//    chunks never look like dropped chunks, so they do not trigger the paid
//    completed-WAV retry; a real drop, drain timeout, or provider failure still does.
//
// Thresholds below are engineering assumptions, not measured optima. They are tuned
// to fail open: a noisy room or audible background music simply keeps streaming.

/// Eligibility and the persisted on/off switch. The switch is read once when a
/// recording creates its realtime session, so one recording never changes policy
/// halfway through. Opt-in; an installation can enable it for the requesting user.
enum RealtimeSilenceSleepPolicy {
    static let userDefaultsKey = "VIPPRealtimeSilenceSleepEnabled"
    static let defaultEnabled = false

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: userDefaultsKey) as? Bool ?? defaultEnabled
    }

    /// Only OpenAI's `gpt-live-transcribe` qualifies. Other realtime providers have
    /// different idle, keepalive, and billing contracts; never extend this gate to
    /// them merely because their sockets also accept PCM.
    static func configuration(
        for model: any TranscriptionModel,
        isEnabled: Bool
    ) -> RealtimeSilenceSleepGate.Configuration? {
        guard isEnabled,
              model.provider == .openAI,
              model.name == OpenAITranscriptionConfiguration.liveModelName else {
            return nil
        }
        return .gptLiveDefault
    }
}

/// Pure, deterministic decision core. It never reads a clock and never touches the
/// network; callers pass the time and apply the returned actions in order. It is not
/// thread-safe; `RealtimeSilenceSleepController` serializes every call.
struct RealtimeSilenceSleepGate {
    struct Configuration: Equatable {
        /// Recorder PCM format: CoreAudioRecorder emits 16 kHz mono little-endian Int16.
        var sampleRate: Double
        /// Short analysis frames, carried across callback/chunk boundaries.
        var analysisFrameSeconds: Double
        /// Audio-time quiet required after the last audible frame before sleeping. This
        /// trailing period gives the `xhigh`-delay model following audio context so the
        /// last spoken words can still be emitted before appends pause.
        var trailingQuietSeconds: Double
        /// Wall-clock hold after this session's own activity (new live words, typing,
        /// an accepted selection or screenshot) before sleeping is allowed.
        var activityHoldSeconds: Double
        /// Most recent quiet audio retained while asleep and sent first on wake, so the
        /// first sounds of speech that preceded the detected onset still reach GPT Live.
        var prerollSeconds: Double
        /// Any frame louder than this is activity regardless of the noise floor. Audible
        /// background music or voices therefore keep the stream awake (fail open).
        var quietCeilingDBFS: Double
        /// A frame this far above the learned floor is activity, even below the ceiling.
        /// This keeps low-gain microphones sensitive to soft speech.
        var wakeMarginDB: Double
        /// Minimum-statistics noise floor: minimum frame level per block, over a short
        /// window of recent blocks. Only already-quiet frames feed it: learning from
        /// active frames can gradually classify sustained soft speech as room noise.
        var noiseFloorBlockSeconds: Double
        var noiseFloorWindowBlocks: Int
        var initialNoiseFloorDBFS: Double
        var minimumNoiseFloorDBFS: Double

        static let gptLiveDefault = Configuration(
            sampleRate: 16_000,
            analysisFrameSeconds: 0.02,
            trailingQuietSeconds: 10,
            activityHoldSeconds: 10,
            prerollSeconds: 0.75,
            quietCeilingDBFS: -65,
            wakeMarginDB: 2,
            noiseFloorBlockSeconds: 0.5,
            noiseFloorWindowBlocks: 6,
            initialNoiseFloorDBFS: -70,
            minimumNoiseFloorDBFS: -100
        )
    }

    enum Action: Equatable {
        /// Forward this exact chunk to the provider stream, in order.
        case send(Data)
        /// Intentionally omitted quiet audio. It remains in the WAV.
        case withhold(Data)
        case sleepingChanged(Bool)
    }

    enum Phase: Equatable {
        case streaming
        case sleeping
        /// Stop, cancel, or a failed handshake ended gating; chunks pass straight through.
        case finished
    }

    let configuration: Configuration
    private(set) var phase: Phase = .streaming
    private var lastActivityAt: TimeInterval
    private var wakeRequested = false
    private var consecutiveQuietSamples = 0
    private var preroll: [Data] = []
    private var prerollSampleCount = 0

    private var frameSumOfSquares: Double = 0
    private var frameSampleCount = 0
    private var currentBlockMinimumDB: Double?
    private var currentBlockSampleCount = 0
    private var recentBlockMinimaDB: [Double] = []

    private let frameLength: Int
    private let blockLength: Int
    private let trailingQuietLength: Int
    private let prerollLength: Int

    init(configuration: Configuration, startedAt: TimeInterval) {
        self.configuration = configuration
        // Creation counts as activity: the stream never sleeps during the first hold.
        lastActivityAt = startedAt
        let rate = max(1, configuration.sampleRate)
        frameLength = max(1, Int((rate * configuration.analysisFrameSeconds).rounded()))
        blockLength = max(frameLength, Int((rate * configuration.noiseFloorBlockSeconds).rounded()))
        trailingQuietLength = max(frameLength, Int((rate * configuration.trailingQuietSeconds).rounded()))
        prerollLength = max(0, Int((rate * configuration.prerollSeconds).rounded()))
    }

    var isSleeping: Bool { phase == .sleeping }

    var noiseFloorDBFS: Double {
        var candidates = recentBlockMinimaDB
        if let currentBlockMinimumDB { candidates.append(currentBlockMinimumDB) }
        let floor = candidates.min() ?? configuration.initialNoiseFloorDBFS
        return max(configuration.minimumNoiseFloorDBFS, floor)
    }

    var activityThresholdDBFS: Double {
        min(configuration.quietCeilingDBFS, noiseFloorDBFS + configuration.wakeMarginDB)
    }

    /// Session activity keeps the stream awake for the hold and wakes a sleeping stream
    /// on the very next chunk. The wake is applied on the audio path so every send stays
    /// in capture order; no chunk is ever sent from two threads.
    mutating func noteActivity(at now: TimeInterval) {
        guard phase != .finished else { return }
        lastActivityAt = max(lastActivityAt, now)
        if phase == .sleeping { wakeRequested = true }
    }

    mutating func process(_ chunk: Data, at now: TimeInterval) -> [Action] {
        guard phase != .finished else { return [.send(chunk)] }
        // CoreAudio guarantees whole PCM16 samples. If another caller breaks that
        // contract, stop omitting audio for this session. Dropping an odd byte count
        // would shift every later sample in the provider's incremental resampler.
        guard chunk.count.isMultiple(of: MemoryLayout<Int16>.size) else {
            return finish() + [.send(chunk)]
        }
        guard !chunk.isEmpty else { return [.send(chunk)] }
        let heardActivity = analyze(chunk)

        switch phase {
        case .streaming:
            var actions: [Action] = [.send(chunk)]
            // Sleep only after BOTH a full trailing period of quiet audio and the
            // session-activity hold. Missing model words alone never qualifies: the
            // audio condition is mandatory, so a slow provider cannot cause a gap.
            if consecutiveQuietSamples >= trailingQuietLength,
               now - lastActivityAt >= configuration.activityHoldSeconds {
                phase = .sleeping
                actions.append(.sleepingChanged(true))
            }
            return actions

        case .sleeping:
            if heardActivity || wakeRequested {
                // Preroll first, then the waking chunk: exactly capture order, each
                // chunk once. The trailing period restarts so a brief sound always
                // streams with following context before the next sleep.
                var actions = preroll.map(Action.send)
                actions.append(.send(chunk))
                preroll.removeAll(keepingCapacity: true)
                prerollSampleCount = 0
                phase = .streaming
                wakeRequested = false
                consecutiveQuietSamples = 0
                actions.append(.sleepingChanged(false))
                return actions
            }
            preroll.append(chunk)
            prerollSampleCount += Self.sampleCount(of: chunk)
            var actions: [Action] = []
            // Keep the smallest run of newest chunks covering the preroll duration.
            while preroll.count > 1,
                  prerollSampleCount - Self.sampleCount(of: preroll[0]) >= prerollLength {
                let evicted = preroll.removeFirst()
                prerollSampleCount -= Self.sampleCount(of: evicted)
                actions.append(.withhold(evicted))
            }
            return actions

        case .finished:
            return [.send(chunk)]
        }
    }

    /// Stop boundary: send any held preroll (fail open: it is at most a fraction of a
    /// second) before the provider's one commit, then pass later chunks through.
    mutating func finish() -> [Action] {
        defer {
            phase = .finished
            wakeRequested = false
        }
        guard phase == .sleeping else { return [] }
        var actions = preroll.map(Action.send)
        preroll.removeAll()
        prerollSampleCount = 0
        actions.append(.sleepingChanged(false))
        return actions
    }

    /// Cancel/reset boundary: nothing more reaches the provider. Held preroll is
    /// accounted as withheld; its audio stays in the WAV like every other frame.
    mutating func discard() -> [Action] {
        defer {
            phase = .finished
            wakeRequested = false
        }
        guard phase == .sleeping else { return [] }
        var actions = preroll.map(Action.withhold)
        preroll.removeAll()
        prerollSampleCount = 0
        actions.append(.sleepingChanged(false))
        return actions
    }

    static func sampleCount(of chunk: Data) -> Int {
        chunk.count / MemoryLayout<Int16>.size
    }

    /// Returns true when any analysis frame completed inside this chunk was audible.
    /// Partial frames carry into the next chunk so an onset that straddles a callback
    /// boundary is measured continuously. Odd-byte chunks disable omission above.
    private mutating func analyze(_ chunk: Data) -> Bool {
        var heardActivity = false
        chunk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Void in
            let count = raw.count
            var index = 0
            while index + 1 < count {
                let bits = UInt16(raw[index]) | (UInt16(raw[index + 1]) << 8)
                if accumulate(Int16(bitPattern: bits)) { heardActivity = true }
                index += 2
            }
        }
        return heardActivity
    }

    private mutating func accumulate(_ sample: Int16) -> Bool {
        let normalized = Double(sample) / 32_768
        frameSumOfSquares += normalized * normalized
        frameSampleCount += 1
        guard frameSampleCount >= frameLength else { return false }

        let rms = (frameSumOfSquares / Double(frameSampleCount)).squareRoot()
        let level = rms > 0 ? 20 * log10(rms) : -120
        let samples = frameSampleCount
        frameSumOfSquares = 0
        frameSampleCount = 0

        // Classify against the floor learned before this frame so a loud onset cannot
        // raise its own threshold, then let the frame update the floor statistics.
        let isActive = level > activityThresholdDBFS
        if isActive {
            consecutiveQuietSamples = 0
        } else {
            recordNoiseFloor(level: level, samples: samples)
            consecutiveQuietSamples += samples
        }
        return isActive
    }

    private mutating func recordNoiseFloor(level: Double, samples: Int) {
        currentBlockMinimumDB = min(currentBlockMinimumDB ?? level, level)
        currentBlockSampleCount += samples
        guard currentBlockSampleCount >= blockLength,
              let minimum = currentBlockMinimumDB else { return }
        recentBlockMinimaDB.append(minimum)
        if recentBlockMinimaDB.count > max(1, configuration.noiseFloorWindowBlocks) {
            recentBlockMinimaDB.removeFirst()
        }
        currentBlockMinimumDB = nil
        currentBlockSampleCount = 0
    }
}

/// Thread-safe owner of one recording's gate. The audio callback (and the startup
/// replay, which the startup router already serializes) calls `receive`; the main
/// actor reports session activity and the stop/cancel boundaries. Every action is
/// applied while the lock is held, so forwarded chunks keep capture order.
final class RealtimeSilenceSleepController: @unchecked Sendable {
    struct Summary: Equatable {
        var sleeps = 0
        var withheldChunks = 0
        var withheldBytes = 0
    }

    private let lock = NSLock()
    private var gate: RealtimeSilenceSleepGate
    private let clock: () -> TimeInterval
    private let forward: (Data) -> Void
    private let withhold: (Data) -> Void
    private let onSleepingChange: (Bool, UInt64) -> Void
    private var generation: UInt64 = 0
    private var summary = Summary()

    /// - Parameters:
    ///   - forward: Enqueue one chunk for the provider. Called with the lock held.
    ///   - withhold: Account one intentionally omitted chunk. Called with the lock held.
    ///   - onSleepingChange: Presentation hook. Called with the lock held and a strictly
    ///     increasing generation so a receiver can discard stale, reordered updates.
    ///     It must not block or call back into this controller.
    init(
        configuration: RealtimeSilenceSleepGate.Configuration,
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        forward: @escaping (Data) -> Void,
        withhold: @escaping (Data) -> Void,
        onSleepingChange: @escaping (Bool, UInt64) -> Void
    ) {
        self.clock = clock
        self.forward = forward
        self.withhold = withhold
        self.onSleepingChange = onSleepingChange
        gate = RealtimeSilenceSleepGate(configuration: configuration, startedAt: clock())
    }

    var isSleeping: Bool {
        lock.lock()
        defer { lock.unlock() }
        return gate.isSleeping
    }

    var summarySnapshot: Summary {
        lock.lock()
        defer { lock.unlock() }
        return summary
    }

    func receive(_ chunk: Data) {
        perform { gate, now in gate.process(chunk, at: now) }
    }

    func noteSessionActivity() {
        lock.lock()
        gate.noteActivity(at: clock())
        lock.unlock()
    }

    func finish() {
        perform { gate, _ in gate.finish() }
    }

    func discard() {
        perform { gate, _ in gate.discard() }
    }

    private func perform(
        _ body: (inout RealtimeSilenceSleepGate, TimeInterval) -> [RealtimeSilenceSleepGate.Action]
    ) {
        lock.lock()
        defer { lock.unlock() }
        let actions = body(&gate, clock())
        for action in actions {
            switch action {
            case .send(let chunk):
                forward(chunk)
            case .withhold(let chunk):
                summary.withheldChunks += 1
                summary.withheldBytes += chunk.count
                withhold(chunk)
            case .sleepingChanged(let sleeping):
                if sleeping { summary.sleeps += 1 }
                generation += 1
                onSleepingChange(sleeping, generation)
            }
        }
    }
}
