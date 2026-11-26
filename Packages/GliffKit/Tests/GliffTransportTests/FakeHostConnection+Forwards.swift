import Synchronization

@testable import GliffTransport

/// One forward or cancel asked of a `FakeHostConnection`.
enum ForwardCall: Hashable, Sendable {
    case forward(PortForward, Loopback)
    case cancel(PortForward, Loopback)
}

/// A fake connection's forwards: the calls in order, the answers a test scripted, and the
/// config's forwards it reports.
struct FakeForwarding: Sendable {
    var calls: [ForwardCall] = []
    /// Each call takes the first answer scripted for it; with none, it succeeds.
    var answers: [ForwardCall: [ForwardError]] = [:]
    var configured = ConfiguredForwards.none
}

extension FakeHostConnection {
    var forwardCalls: [ForwardCall] { forwarding.withLock { $0.calls } }

    /// The next forward of `forward` on `loopback` fails with `error`.
    func answer(_ forward: PortForward, on loopback: Loopback, with error: ForwardError) {
        script(.forward(forward, loopback), error)
    }

    /// The next cancel of `forward` on `loopback` fails with `error`.
    func answerCancel(_ forward: PortForward, on loopback: Loopback, with error: ForwardError) {
        script(.cancel(forward, loopback), error)
    }

    func forward(_ forward: PortForward, on loopback: Loopback) async throws(ForwardError) {
        try take(.forward(forward, loopback))
    }

    func cancel(_ forward: PortForward, on loopback: Loopback) async throws(ForwardError) {
        try take(.cancel(forward, loopback))
    }

    var configuredForwards: ConfiguredForwards {
        get { forwarding.withLock { $0.configured } }
        set { forwarding.withLock { $0.configured = newValue } }
    }

    private func script(_ call: ForwardCall, _ error: ForwardError) {
        forwarding.withLock { $0.answers[call, default: []].append(error) }
    }

    private func take(_ call: ForwardCall) throws(ForwardError) {
        let error = forwarding.withLock { state -> ForwardError? in
            state.calls.append(call)
            guard var queued = state.answers[call], !queued.isEmpty else { return nil }
            let first = queued.removeFirst()
            state.answers[call] = queued
            return first
        }
        if let error { throw error }
    }
}
