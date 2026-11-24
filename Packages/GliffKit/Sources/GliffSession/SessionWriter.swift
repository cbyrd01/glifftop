import GliffTransport
import Synchronization

/// The session's one writer: frames are queued without waiting and written in order by a
/// single task, so a slow pipe never blocks the reader. Bulk frames (clipboard data) go only
/// when no other frame waits, so input and acks never queue behind a large paste.
struct SessionWriter: Sendable {
    /// A frame and its message's type, for the observer.
    private struct Outgoing: Sendable {
        let bytes: [UInt8]
        let type: String
    }

    private let queue = FrameQueue<Outgoing>()
    private let task: Task<Void, Never>

    /// `failed` is called once if a write fails; later frames are dropped. `observer` hears of
    /// each frame once written.
    init(
        connection: any ByteConnection, observer: (any ProtocolObserver)? = nil,
        failed: @escaping @Sendable (any Error) async -> Void
    ) {
        task = Task { [queue] in
            while let frame = await queue.next() {
                do {
                    try await connection.write(frame.bytes)
                } catch {
                    await failed(error)
                    return
                }
                observer?.observed(
                    ProtocolEvent(direction: .sent, type: frame.type, bytes: frame.bytes.count, time: .now))
            }
        }
    }

    func send(_ bytes: [UInt8], type: String) {
        queue.push(Outgoing(bytes: bytes, type: type), bulk: false)
    }

    func sendBulk(_ bytes: [UInt8], type: String) {
        queue.push(Outgoing(bytes: bytes, type: type), bulk: true)
    }

    /// Takes no more frames, drops the bulk ones still queued, and waits up to `limit` for the
    /// rest to be written. A write still stuck after that is ended by closing the connection.
    func drain(within limit: Duration) async {
        queue.finish()
        let task = self.task
        let once = Once()
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            once.set(waiter)
            Task {
                await task.value
                once.resume()
            }
            Task {
                try? await Task.sleep(for: limit)
                once.resume()
            }
        }
    }
}

/// The writer's two lanes, each in order: urgent frames first, but a waiting bulk frame goes
/// after every `urgentRun` urgent ones, so a stream of input never starves a transfer into its
/// timeout.
final class FrameQueue<Item: Sendable>: Sendable {
    static var urgentRun: Int { 8 }

    private struct State {
        var urgent: [Item] = []
        var bulk: [Item] = []
        /// Urgent frames taken in a row while bulk waited.
        var streak = 0
        var finished = false
        var waiter: CheckedContinuation<Item?, Never>?
    }

    private let state = Mutex(State())

    func push(_ item: Item, bulk: Bool) {
        let waiter = state.withLock { state -> CheckedContinuation<Item?, Never>? in
            guard !state.finished else { return nil }
            if let waiter = state.waiter {
                state.waiter = nil
                return waiter
            }
            if bulk { state.bulk.append(item) } else { state.urgent.append(item) }
            return nil
        }
        waiter?.resume(returning: item)
    }

    /// The next frame to write, waiting for one; nil once finished and empty.
    func next() async -> Item? {
        await withCheckedContinuation { waiter in
            let ready = state.withLock { state -> Item?? in
                if !state.bulk.isEmpty, state.urgent.isEmpty || state.streak >= Self.urgentRun {
                    state.streak = 0
                    return state.bulk.removeFirst()
                }
                if !state.urgent.isEmpty {
                    if !state.bulk.isEmpty { state.streak += 1 }
                    return state.urgent.removeFirst()
                }
                if state.finished { return .some(nil) }
                state.waiter = waiter
                return nil
            }
            if let ready { waiter.resume(returning: ready) }
        }
    }

    func finish() {
        let waiter = state.withLock { state in
            state.finished = true
            state.bulk = []
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(returning: nil)
    }
}

/// Resumes a continuation exactly once, whichever caller comes first.
private final class Once: Sendable {
    private let waiter = Mutex<CheckedContinuation<Void, Never>?>(nil)

    func set(_ continuation: CheckedContinuation<Void, Never>) {
        waiter.withLock { $0 = continuation }
    }

    func resume() {
        waiter.withLock { waiter in
            waiter?.resume()
            waiter = nil
        }
    }
}
