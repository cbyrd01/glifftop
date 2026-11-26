import Synchronization

@testable import GliffTransport

/// A channel that never speaks unless told to: what a test writes is kept, and `incoming`
/// yields or fails when the test says.
final class FakeChannel: ByteConnection {
    let incoming: AsyncThrowingStream<[UInt8], any Error>
    private let continuation: AsyncThrowingStream<[UInt8], any Error>.Continuation
    private let state = Mutex((written: [UInt8](), closed: false))
    private let writesFail: Bool

    init(writesFail: Bool = false) {
        (incoming, continuation) = AsyncThrowingStream.makeStream()
        self.writesFail = writesFail
    }

    var written: [UInt8] { state.withLock { $0.written } }
    var isClosed: Bool { state.withLock { $0.closed } }

    func write(_ bytes: [UInt8]) async throws(TransportError) {
        if writesFail { throw .writeFailed("broken pipe") }
        state.withLock { $0.written += bytes }
    }

    func close() async {
        state.withLock { $0.closed = true }
        continuation.finish()
    }

    func send(_ bytes: [UInt8]) { continuation.yield(bytes) }
    /// The command exits successfully.
    func end() { continuation.finish() }
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
        var channelFailure: TransportError?
    }

    private let state = Mutex(State())
    /// Forwards asked of it, and its scripted answers (`FakeHostConnection+Forwards`).
    let forwarding = Mutex(FakeForwarding())
    private let writesFail: Bool
    /// Each close waits on this before it ends the connection (a slow `-O exit`).
    private let closeGate: CloseGate?
    /// Each channel's open waits on this, when set.
    private let channelGate = Mutex<CloseGate?>(nil)

    init(writesFail: Bool = false, closeGate: CloseGate? = nil) {
        (self.writesFail, self.closeGate) = (writesFail, closeGate)
    }

    var commands: [String] { state.withLock { $0.commands } }
    var channels: [FakeChannel] { state.withLock { $0.channels } }
    var closeCount: Int { state.withLock { $0.closed } }
    var invalidateCount: Int { state.withLock { $0.invalidated } }

    /// Channels asked for from now on open only once `gate` opens.
    func holdChannels(_ gate: CloseGate) { channelGate.withLock { $0 = gate } }

    /// The next channel asked for fails to open with `failure`.
    func failNextChannel(_ failure: TransportError) { state.withLock { $0.channelFailure = failure } }

    func channel(command: String) async throws(TransportError) -> any ByteConnection {
        await channelGate.withLock { $0 }?.pass()
        let channel = FakeChannel(writesFail: writesFail)
        let failure = state.withLock { state -> TransportError? in
            defer { state.channelFailure = nil }
            guard state.channelFailure == nil else { return state.channelFailure }
            state.commands.append(command)
            state.channels.append(channel)
            return nil
        }
        if let failure { throw failure }
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
        await closeGate?.pass()
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
        var writesFail = false
        var cancelled = 0
        var closeGate: CloseGate?
        var questions: [SignInQuestion] = []
        var askedWith: [Bool] = []
        var answers: [String] = []
        var detaching = false
        var detachedFailure: TransportError?
    }

    private let state = Mutex(State())

    var calls: Int { state.withLock { $0.calls } }
    /// How many opens had their task cancelled (they still go on, as a slow one might).
    var cancelledCount: Int { state.withLock { $0.cancelled } }
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

    /// Each open from now on asks these, as ssh would: Cancel fails it as `signInCancelled`,
    /// Deny as `hostKeyDenied`.
    func ask(_ questions: [SignInQuestion]) { state.withLock { $0.questions = questions } }
    /// From now on each open asks its questions without waiting for answers, as ssh shows a
    /// notice; at `release()` it ends them, as ssh kills a notice's helper, and fails with
    /// `failure`.
    func detachQuestions(then failure: TransportError) {
        state.withLock { state in
            state.detaching = true
            state.detachedFailure = failure
        }
    }

    /// Whether each open was given someone to ask.
    var askedWith: [Bool] { state.withLock { $0.askedWith } }
    /// What each question was answered: allow, deny, secret or cancel.
    var answers: [String] { state.withLock { $0.answers } }

    /// Closes of connections opened from now on wait until `gate` opens.
    func holdCloses(_ gate: CloseGate) { state.withLock { $0.closeGate = gate } }

    /// Channels on connections opened from now on fail every write.
    func failChannelWrites() { state.withLock { $0.writesFail = true } }

    var open: HostConnections.Open {
        { [self] _, asker throws(TransportError) in try await self.open(asker) }
    }

    private func open(_ asker: (any SignInAsker)?) async throws(TransportError) -> any HostConnection {
        state.withLock { state in
            state.calls += 1
            state.askedWith.append(asker != nil)
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let goOn = state.withLock { state in
                    if state.held { state.waiting.append(continuation) }
                    return !state.held
                }
                if goOn { continuation.resume() }
            }
        } onCancel: {
            state.withLock { $0.cancelled += 1 }
        }
        if let failure = state.withLock({ $0.failures.isEmpty ? nil : $0.failures.removeFirst() }) {
            throw failure
        }
        if state.withLock(\.detaching) { try await askDetached(asker) }
        for question in state.withLock({ $0.questions }) {
            guard let asker else { throw .exited(status: 255, failure: .permissionDenied) }
            let answer: String =
                switch await asker.ask(question) {
                case .allow: "allow"
                case .deny: "deny"
                case .secret: "secret"
                case .cancel: "cancel"
                }
            state.withLock { $0.answers.append(answer) }
            if answer == "cancel" { throw .exited(status: 255, failure: .signInCancelled) }
            if answer == "deny" { throw .exited(status: 255, failure: .hostKeyDenied) }
        }
        let (writesFail, closeGate) = state.withLock { ($0.writesFail, $0.closeGate) }
        return made(writesFail: writesFail, closeGate: closeGate)
    }

    private func askDetached(_ asker: (any SignInAsker)?) async throws(TransportError) {
        let questions = state.withLock { $0.questions }
        guard !questions.isEmpty else { return }
        let tasks = questions.map { question in Task { _ = await asker?.ask(question) } }
        await withCheckedContinuation { continuation in state.withLock { $0.waiting.append(continuation) } }
        for task in tasks { task.cancel() }
        for task in tasks { await task.value }
        if let failure = state.withLock(\.detachedFailure) { throw failure }
    }

    private func made(writesFail: Bool, closeGate: CloseGate?) -> any HostConnection {
        let connection = FakeHostConnection(writesFail: writesFail, closeGate: closeGate)
        state.withLock { $0.made.append(connection) }
        return connection
    }
}

/// Holds whoever passes until opened.
final class CloseGate: Sendable {
    private let state = Mutex<(open: Bool, waiting: [CheckedContinuation<Void, Never>])>((false, []))

    func pass() async {
        await withCheckedContinuation { continuation in
            let open = state.withLock { state in
                if !state.open { state.waiting.append(continuation) }
                return state.open
            }
            if open { continuation.resume() }
        }
    }

    /// How many wait to pass.
    var waitingCount: Int { state.withLock { $0.waiting.count } }

    func open() {
        let waiting = state.withLock { state in
            state.open = true
            defer { state.waiting = [] }
            return state.waiting
        }
        for continuation in waiting { continuation.resume() }
    }
}

/// Polls `condition` for up to `limit` of real time: for effects another task carries out.
func eventually(within limit: Duration = .seconds(2), _ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + limit
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}
