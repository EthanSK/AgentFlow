import Combine
import Foundation

/// Paired Voice work belongs to the same cooperative-quit boundary as local recordings.
/// Ethan's "wait till I'm finished speaking" applies on the receiving Mac too: quitting it
/// must not forget a mute that another Mac still needs, or drop its final network release.
///
/// The receiver works off the main thread. A lock makes admitting one request and committing
/// an idle quit mutually exclusive; a delayed main-thread notification alone leaves a race
/// where Quit could pass just before a background request posts the mute. No timer, AX read,
/// microphone action or network wait belongs in this activity check.
final class PairedVoiceMuteActivity: @unchecked Sendable {
    static let shared = PairedVoiceMuteActivity()

    private let lock = NSLock()
    private let subject = PassthroughSubject<Void, Never>()
    private var operations: Set<UUID> = []
    private var hasRemoteCapture = false
    private var closing = false

    var hasWork: Bool {
        lock.lock()
        defer { lock.unlock() }
        return hasWorkLocked
    }

    /// UI consumers run on the main thread; the truth is updated synchronously under the lock.
    var changes: AnyPublisher<Void, Never> {
        subject.receive(on: DispatchQueue.main).eraseToAnyPublisher()
    }

    func beginOperation() -> UUID? {
        lock.lock()
        guard !closing else { lock.unlock(); return nil }
        let wasBusy = hasWorkLocked
        let token = UUID()
        operations.insert(token)
        lock.unlock()
        if !wasBusy { subject.send(()) }
        return token
    }

    /// Only the serialized recipient coordinator supplies `remoteCaptureActive`. Outbound
    /// SSH completion must leave that independent ownership untouched. Keep the operation
    /// registered through restoration, even after the ledger removes its last capture owner.
    func finishOperation(_ token: UUID, remoteCaptureActive: Bool? = nil) {
        lock.lock()
        guard operations.remove(token) != nil else { lock.unlock(); return }
        if let remoteCaptureActive { hasRemoteCapture = remoteCaptureActive }
        let isBusy = hasWorkLocked
        lock.unlock()
        if !isBusy { subject.send(()) }
    }

    /// Called only when the app's other session/start/retry checks are also idle. Once this
    /// returns true, later receiver work is rejected instead of posting a mute during exit.
    func closeIfIdle() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !hasWorkLocked else { return false }
        closing = true
        return true
    }

    private var hasWorkLocked: Bool { hasRemoteCapture || !operations.isEmpty }
}
