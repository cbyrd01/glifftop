import Synchronization

@testable import GliffTransport

/// A channel that never speaks unless told to: what a test writes is kept, and `incoming`
/// yields or fails when the test says.
final class FakeChannel: ByteConnection {
    let incoming: AsyncThrowingStream<[UInt8], any Error>
    private let continuation: AsyncThrowingStream<[UInt8], any Error>.Continuation
    private let state = Mutex((written: [UInt8](), closed: false))

    init() {
        (incoming, continuation) = AsyncThrowingStream.makeStream()
    }

    var written: [UInt8] { state.withLock { $0.written } }
    var isClosed: Bool { state.withLock { $0.closed } }

    func write(_ bytes: [UInt8]) async throws(TransportError) {
        state.withLock { $0.written += bytes }
    }

    func close() async {
        state.withLock { $0.closed = true }
        continuation.finish()
    }

    func send(_ bytes: [UInt8]) { continuation.yield(bytes) }
    func fail(_ error: TransportError) { continuation.finish(throwing: error) }
}

/// A connection a test drives: it records each channel's command and hands out `FakeChannel`s,
/// and ends when the test loses it or something closes it.
final class FakeHostConnection: HostConnection {
    private struct State {
        var commands: [String] = []
        var channels: [FakeChannel] = []
        var closed = 0
        var invalidated = 0
        var end: ConnectFailure??
        var waiter: CheckedContinuation<ConnectFailure?, Never>?
    }

    private let state = Mutex(State())

    var commands: [String] { state.withLock { $0.commands } }
    var channels: [FakeChannel] { state.withLock { $0.channels } }
    var closeCount: Int { state.withLock { $0.closed } }
    var invalidateCount: Int { state.withLock { $0.invalidated } }

    func channel(command: String) async throws(TransportError) -> any ByteConnection {
        let channel = FakeChannel()
        state.withLock {
            $0.commands.append(command)
            $0.channels.append(channel)
        }
        return channel
    }

    func ended() async -> ConnectFailure? {
        await withCheckedContinuation { continuation in
            let done: ConnectFailure?? = state.withLock { state in
                if let end = state.end { return end }
                state.waiter = continuation
                return nil
            }
            if let done { continuation.resume(returning: done) }
        }
    }

    func invalidate() async {
        state.withLock { $0.invalidated += 1 }
        finish(.unreachable)
    }

    func close() async {
        state.withLock { $0.closed += 1 }
        finish(nil)
    }

    /// The link is gone, as if the master exited.
    func lose(_ failure: ConnectFailure) { finish(failure) }

    private func finish(_ failure: ConnectFailure?) {
        let waiter = state.withLock { state -> CheckedContinuation<ConnectFailure?, Never>? in
            guard state.end == nil else { return nil }
            state.end = .some(failure)
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(returning: failure)
    }
}

/// Opens `FakeHostConnection`s, counting each open; it can hold opens until released, and fail
/// the next ones.
final class FakeOpener: Sendable {
    private struct State {
        var calls = 0
        var held = false
        var waiting: [CheckedContinuation<Void, Never>] = []
        var failures: [TransportError] = []
        var made: [FakeHostConnection] = []
    }

    private let state = Mutex(State())

    var calls: Int { state.withLock { $0.calls } }
    var made: [FakeHostConnection] { state.withLock { $0.made } }
    /// How many opens are waiting for `release()`.
    var waitingCount: Int { state.withLock { $0.waiting.count } }

    func hold() { state.withLock { $0.held = true } }

    func release() {
        let waiting = state.withLock { state in
            state.held = false
            defer { state.waiting = [] }
            return state.waiting
        }
        for continuation in waiting { continuation.resume() }
    }

    func failNext(_ error: TransportError) { state.withLock { $0.failures.append(error) } }

    var open: HostConnections.Open {
        { [self] _ throws(TransportError) in try await self.open() }
    }

    private func open() async throws(TransportError) -> any HostConnection {
        state.withLock { $0.calls += 1 }
        await withCheckedContinuation { continuation in
            let goOn = state.withLock { state in
                if state.held { state.waiting.append(continuation) }
                return !state.held
            }
            if goOn { continuation.resume() }
        }
        if let failure = state.withLock({ $0.failures.isEmpty ? nil : $0.failures.removeFirst() }) {
            throw failure
        }
        let connection = FakeHostConnection()
        state.withLock { $0.made.append(connection) }
        return connection
    }
}

/// Polls `condition` for up to 2 s of real time: for effects another task carries out.
func eventually(_ condition: () async -> Bool) async -> Bool {
    for _ in 0..<200 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}
