import GliffTransport
import Synchronization

/// A forward or cancel a connection was asked for, in order.
enum PortsCall: Hashable, Sendable {
    case forward(Int, Loopback)
    case cancel(Int, Loopback)
}

/// A connection for HostPorts' tests: it records forwards and cancels by local port, answers
/// as scripted, holds a blocked call until released, and ends when told. It mirrors GliffTransportTests' `FakeHostConnection`,
/// which this target can't see.
final class PortsFakeConnection: HostConnection {
    private struct State {
        var calls: [PortsCall] = []
        var answers: [PortsCall: [ForwardError]] = [:]
        var configured = ConfiguredForwards.none
        var end: ConnectFailure??
        var waiters: [CheckedContinuation<ConnectFailure?, Never>] = []
        var blocked: Set<PortsCall?> = []
        var parked: [PortsCall?: CheckedContinuation<Void, Never>] = [:]
    }

    private let state: Mutex<State>

    init(configured: ConfiguredForwards = .none) {
        state = Mutex(State(configured: configured))
    }

    var calls: [PortsCall] { state.withLock { $0.calls } }

    /// The next `call` fails with `error`.
    func answer(_ call: PortsCall, with error: ForwardError) {
        state.withLock { $0.answers[call, default: []].append(error) }
    }

    /// The next `call` (nil: the next read of the configured forwards) is answered as it
    /// comes, then waits for `release`, and is recorded once it returns.
    func block(_ call: PortsCall?) { _ = state.withLock { $0.blocked.insert(call) } }

    /// Whether a blocked `call` is waiting.
    func isParked(_ call: PortsCall?) -> Bool { state.withLock { $0.parked[call] != nil } }

    func release(_ call: PortsCall?) {
        state.withLock { $0.parked.removeValue(forKey: call) }?.resume()
    }

    private func gate(_ call: PortsCall?) async {
        await withCheckedContinuation { continuation in
            let wait = state.withLock { state in
                guard state.blocked.remove(call) != nil else { return false }
                state.parked[call] = continuation
                return true
            }
            if !wait { continuation.resume() }
        }
    }

    func channel(command: String) async throws(TransportError) -> any ByteConnection {
        throw .cancelled
    }

    func forward(_ forward: PortForward, on loopback: Loopback) async throws(ForwardError) {
        try await take(.forward(forward.localPort, loopback))
    }

    func cancel(_ forward: PortForward, on loopback: Loopback) async throws(ForwardError) {
        try await take(.cancel(forward.localPort, loopback))
    }

    private func take(_ call: PortsCall) async throws(ForwardError) {
        let error = state.withLock { state -> ForwardError? in
            if state.end != nil { return .connectionLost }
            guard var answers = state.answers[call], !answers.isEmpty else { return nil }
            let first = answers.removeFirst()
            state.answers[call] = answers
            return first
        }
        await gate(call)
        state.withLock { $0.calls.append(call) }
        if let error { throw error }
    }

    var configuredForwards: ConfiguredForwards {
        get async {
            let configured = state.withLock { $0.configured }
            await gate(nil)
            return configured
        }
    }

    func ended() async -> ConnectFailure? {
        await withCheckedContinuation { continuation in
            let done: ConnectFailure?? = state.withLock { state in
                if let end = state.end { return end }
                state.waiters.append(continuation)
                return nil
            }
            if let done { continuation.resume(returning: done) }
        }
    }

    func invalidate() async { finish(.unreachable) }

    func close() async { finish(nil) }

    /// The link is gone, as if the master exited.
    func lose() { finish(.unreachable) }

    private func finish(_ failure: ConnectFailure?) {
        let waiters = state.withLock { state -> [CheckedContinuation<ConnectFailure?, Never>] in
            guard state.end == nil else { return [] }
            state.end = .some(failure)
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume(returning: failure) }
    }
}

/// Opens `PortsFakeConnection`s in order, each with the configured forwards set at the time.
final class PortsOpener: Sendable {
    private let state = Mutex((made: [PortsFakeConnection](), configured: ConfiguredForwards.none))

    var made: [PortsFakeConnection] { state.withLock { $0.made } }

    func configure(_ configured: ConfiguredForwards) { state.withLock { $0.configured = configured } }

    var open: HostConnections.Open {
        { [self] _, _ in
            state.withLock { state in
                let connection = PortsFakeConnection(configured: state.configured)
                state.made.append(connection)
                return connection
            }
        }
    }
}

/// A loopback check whose taken and IPv4-only ports a test changes as it goes.
final class PortsMac: Sendable {
    private let state = Mutex((taken: Set<Int>(), ipv4Only: Set<Int>(), checked: [Int]()))

    func take(_ ports: Int...) { state.withLock { $0.taken.formUnion(ports) } }
    func free(_ ports: Int...) { state.withLock { $0.taken.subtract(ports) } }
    func ipv4Only(_ ports: Int...) { state.withLock { $0.ipv4Only.formUnion(ports) } }
    var checked: [Int] { state.withLock { $0.checked } }

    var check: @Sendable (Int) -> LoopbackPorts.Availability {
        { [self] port in
            state.withLock { state in
                state.checked.append(port)
                if state.taken.contains(port) { return .taken }
                return state.ipv4Only.contains(port) ? .freeIPv4Only : .free
            }
        }
    }

    var pick: @Sendable () -> Int? { { 50001 } }
}

/// Whether `condition` holds within `seconds`, polled.
func eventually(_ seconds: Double = 5, _ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}
