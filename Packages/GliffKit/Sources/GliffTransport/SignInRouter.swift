import Synchronization

/// One open's sign-in questions, each put to a window waiting for that open
/// (`HostConnections.startAsking`):
///
/// - The oldest waiter with an asker is asked; a question about a host key (an unknown key, or
///   ssh's yes/no warnings) only one that is `fresh`, an attempt the person started. With
///   askers but none fresh, it is denied, and the open's `hostKeyDenied` becomes
///   `hostKeyUnchecked`: a reconnect never asks about a key.
/// - A waiter that stops waiting has its question cancelled and its answer ignored; the
///   question goes to the next. With nobody to ask, it waits up to the open's grace for a
///   window (a listing's sign-in passes to the session it starts), then is cancelled, a cancel
///   that isn't remembered as the person's. A cancelled open cancels it at once.
final class SignInRouter: SignInAsker {
    private let connections: HostConnections
    private let key: String
    private let generation: Int

    init(connections: HostConnections, key: String, generation: Int) {
        (self.connections, self.key, self.generation) = (connections, key, generation)
    }

    func ask(_ question: SignInQuestion) async -> SignInAnswer {
        var waited = false
        asking: while !Task.isCancelled {
            switch await connections.startAsking(question, key: key, generation: generation) {
            case .nobody:
                if waited { break asking }
                waited = true
                await connections.waitForAsker(key: key, generation: generation)
            case .deny: return .deny
            case .asking(let id, let task, let slot):
                waited = false
                await withTaskCancellationHandler {
                    await task.value
                } onCancel: {
                    task.cancel()
                }
                let stillWaiting = await connections.finishAsking(id, key: key)
                if stillWaiting, !Task.isCancelled, let answer = slot.take() { return answer }
            }
        }
        await connections.cancelledForNobody(key: key, generation: generation)
        return .cancel
    }
}

extension SignInQuestion {
    /// An unknown key, or ssh's yes/no warnings about one: for a connection the person starts.
    var isAboutHostKey: Bool {
        switch self {
        case .hostKey, .confirm: true
        default: false
        }
    }
}

/// Set as a waiter's task is cancelled, before the connections hear of it.
final class LeavingMark: Sendable {
    private let mark = Mutex(false)
    func set() { mark.withLock { $0 = true } }
    var isSet: Bool { mark.withLock { $0 } }
}

/// Holds an answer from the task that asked until the router takes it; one never taken is
/// dropped with its secret.
final class AnswerSlot: Sendable {
    private let answer = Mutex<SignInAnswer?>(nil)

    func put(_ value: consuming SignInAnswer) {
        var value: SignInAnswer? = consume value
        answer.withLock { $0 = value.take() }
    }

    func take() -> SignInAnswer? { answer.withLock { $0.take() } }
}
