import GliffInput
import Synchronization

/// What the app queues for the session, in the order it happened.
enum Queued: Equatable, Sendable {
    case input(InputMessage)
    /// A clipboard offer or revoke: input after it waits until it is on its way.
    case clipboard(ClipboardCommand)
}

/// Input from the app, in order, waiting for the session: `Session.send` appends from any
/// thread at once; the session takes what is queued each time `wakeups` fires. Closed
/// when the session ends: nothing is kept after, and `wakeups` ends.
final class InputQueue: Sendable {
    /// nil once closed.
    private let pending = Mutex<[Queued]?>([])
    /// Fires after an append; several appends may share one wakeup.
    let wakeups: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        (wakeups, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    func append(_ input: InputMessage) {
        append(.input(input))
    }

    func append(_ item: Queued) {
        pending.withLock { $0?.append(item) }
        continuation.yield()
    }

    func close() {
        pending.withLock { $0 = nil }
        continuation.finish()
    }

    func takeAll() -> [InputMessage] {
        pending.withLock { pending in
            guard let taken = pending else { return [] }
            pending = []
            return taken.compactMap { if case .input(let input) = $0 { input } else { nil } }
        }
    }

    /// The input queued before the first clipboard command, and that command; what follows it
    /// stays queued.
    func takeUntilClipboard() -> (inputs: [InputMessage], command: ClipboardCommand?) {
        pending.withLock { pending in
            guard let queued = pending else { return ([], nil) }
            var inputs: [InputMessage] = []
            for (index, item) in queued.enumerated() {
                switch item {
                case .input(let input): inputs.append(input)
                case .clipboard(let command):
                    pending = Array(queued[(index + 1)...])
                    return (inputs, command)
                }
            }
            pending = []
            return (inputs, nil)
        }
    }
}
