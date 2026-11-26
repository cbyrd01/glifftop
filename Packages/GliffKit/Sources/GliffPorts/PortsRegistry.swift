public import GliffTransport
import Synchronization

/// The app's `HostPorts`, one per destination as typed (the `HostConnections` key): made on a
/// window's first hold, dropped once its grace has run out.
public actor PortsRegistry {
    private let connections: HostConnections
    private let clock: any Clock<Duration>
    private let chooser: LocalPortChooser
    private var hosts: [String: HostPorts] = [:]
    private var nextHold = 0
    private let automatic = AutomaticSetting()
    private nonisolated let hub = SnapshotHub()

    public init(
        connections: HostConnections, clock: any Clock<Duration> = ContinuousClock(),
        check: @escaping @Sendable (Int) -> LoopbackPorts.Availability = LoopbackPorts.check,
        pick: @escaping @Sendable () -> Int? = LoopbackPorts.pick
    ) {
        (self.connections, self.clock) = (connections, clock)
        chooser = LocalPortChooser(check: check, pick: pick)
    }

    /// A window's hold on `target`'s ports, with its saved forwards.
    public func hold(_ target: SSHTarget, saved: [PortForward]) async -> PortsHold {
        nextHold += 1
        let id = nextHold
        while true {
            let ports = hosts[target.value] ?? make(target)
            if await ports.addHold(id, saved: saved) { return PortsHold(ports: ports, id: id) }
        }
    }

    private func make(_ target: SSHTarget) -> HostPorts {
        let key = target.value
        let hub = hub
        let ports = HostPorts(
            target: target, connections: connections, clock: clock, chooser: chooser,
            publish: { hub.publish($0, for: key) }, automatic: automatic,
            finished: { [weak self] ports in await self?.drop(ports, key) })
        hosts[key] = ports
        return ports
    }

    /// Whether new ports are forwarded without a notice, on every host's ports from now on.
    public func setAutomatic(_ on: Bool) { automatic.set(on) }

    /// `target`'s ports while a window holds them or their grace runs.
    public func ports(for target: SSHTarget) -> HostPorts? { hosts[target.value] }

    /// `target`'s snapshots from now on, the latest first; an empty one once its ports are
    /// dropped. One stream per call.
    public nonisolated func snapshots(for target: SSHTarget) -> AsyncStream<PortsSnapshot> {
        hub.stream(for: target.value)
    }

    private func drop(_ ports: HostPorts, _ key: String) {
        guard hosts[key] === ports else { return }
        hosts[key] = nil
        hub.publish(PortsSnapshot(), for: key)
    }
}

/// The snapshot streams, by destination, and the latest snapshot of each.
final class SnapshotHub: Sendable {
    private struct State {
        var sinks: [String: [Int: AsyncStream<PortsSnapshot>.Continuation]] = [:]
        var latest: [String: PortsSnapshot] = [:]
        var next = 0
    }

    private let state = Mutex(State())

    func publish(_ snapshot: PortsSnapshot, for key: String) {
        let sinks = state.withLock { state in
            state.latest[key] = snapshot
            return Array((state.sinks[key] ?? [:]).values)
        }
        for sink in sinks { sink.yield(snapshot) }
    }

    func stream(for key: String) -> AsyncStream<PortsSnapshot> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: PortsSnapshot.self, bufferingPolicy: .bufferingNewest(1))
        let id = state.withLock { state in
            state.next += 1
            state.sinks[key, default: [:]][state.next] = continuation
            if let latest = state.latest[key] { continuation.yield(latest) }
            return state.next
        }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { state in
                state.sinks[key]?[id] = nil
                if state.sinks[key]?.isEmpty == true { state.sinks[key] = nil }
            }
        }
        return stream
    }
}

/// "Forward new ports automatically", as every host's ports read it.
final class AutomaticSetting: Sendable {
    private let state = Mutex(false)

    var isOn: Bool { state.withLock { $0 } }

    func set(_ on: Bool) { state.withLock { $0 = on } }
}
