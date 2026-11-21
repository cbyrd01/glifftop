import GliffTransport
import Synchronization

/// The session's one writer: frames are queued without waiting and written in order by a
/// single task, so a slow pipe never blocks the reader. Bulk frames (clipboard data) go only
/// when no other frame waits, so input and acks never queue behind a large paste.
struct SessionWriter: Sendable {
    private let queue = FrameQueue()
    private let task: Task<Void, Never>

    /// `failed` is called once if a write fails; later frames are dropped.
    init(connection: any ByteConnection, failed: @escaping @Sendable (any Error) async -> Void) {
        task = Task { [queue] in
            while let bytes = await queue.next() {
                do {
                    try await connection.write(bytes)
                } catch {
                    await failed(error)
                    return
                }
            }
        }
    }

    func send(_ bytes: [UInt8]) {
        queue.push(bytes, bulk: false)
    }

    func sendBulk(_ bytes: [UInt8]) {
        queue.push(bytes, bulk: true)
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
final class FrameQueue: Sendable {
    static let urgentRun = 8

    private struct State {
        var urgent: [[UInt8]] = []
        var bulk: [[UInt8]] = []
        /// Urgent frames taken in a row while bulk waited.
        var streak = 0
        var finished = false
        var waiter: CheckedContinuation<[UInt8]?, Never>?
    }

    private let state = Mutex(State())

    func push(_ bytes: [UInt8], bulk: Bool) {
        let waiter = state.withLock { state -> CheckedContinuation<[UInt8]?, Never>? in
            guard !state.finished else { return nil }
            if let waiter = state.waiter {
                state.waiter = nil
                return waiter
            }
            if bulk { state.bulk.append(bytes) } else { state.urgent.append(bytes) }
            return nil
        }
        waiter?.resume(returning: bytes)
    }

    /// The next frame to write, waiting for one; nil once finished and empty.
    func next() async -> [UInt8]? {
        await withCheckedContinuation { waiter in
            let ready = state.withLock { state -> [UInt8]?? in
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
