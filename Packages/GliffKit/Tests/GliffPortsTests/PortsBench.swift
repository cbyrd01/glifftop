import GliffTestSupport
import GliffTransport
import Testing

@testable import GliffPorts

/// A host for the watcher's and the offers' tests: two places per connection, so one tab
/// leaves a spare for the watcher.
struct PortsBench {
    let clock = ManualClock()
    let connectionClock = ManualClock()
    let opener = PortsOpener()
    let mac = PortsMac()
    let connections: HostConnections
    let registry: PortsRegistry

    init() {
        connections = HostConnections(open: opener.open, clock: connectionClock, leaseLimit: 2)
        registry = PortsRegistry(connections: connections, clock: clock, check: mac.check, pick: mac.pick)
    }

    func omarchy() throws -> SSHTarget { try SSHTarget("omarchy") }

    func ports() async throws -> HostPorts { try #require(await registry.ports(for: omarchy())) }

    func snapshot() async throws -> PortsSnapshot { try await ports().snapshot }

    /// The first connection's watcher channel number `index`, once it is open.
    func channel(_ index: Int = 0) async throws -> PortsChannel {
        #expect(await eventually { opener.made.first.map { $0.channels.count > index } ?? false })
        return try #require(opener.made.first?.channels.dropFirst(index).first)
    }

    /// A tab and a hold on omarchy, with the watcher's first channel.
    func watching() async throws -> (tab: HostLease, hold: PortsHold, channel: PortsChannel) {
        let tab = try await connections.lease(for: omarchy())
        let hold = await registry.hold(try omarchy(), saved: [])
        return (tab, hold, try await channel())
    }

    /// Waits until the snapshot satisfies `condition`.
    func until(_ condition: @escaping (PortsSnapshot) -> Bool) async -> Bool {
        await eventually { (try? await snapshot()).map(condition) ?? false }
    }

    /// The watcher has a channel, has read a first frame of `ports`, and they are Available.
    func firstFrame(_ ports: [(Int, String?)]) async throws -> (
        tab: HostLease, hold: PortsHold, channel: PortsChannel
    ) {
        let watching = try await watching()
        watching.channel.send(ports)
        #expect(await until { $0.available.map(\.port) == ports.map(\.0).sorted() })
        return watching
    }

    func row(_ remote: Int) async throws -> ForwardRow? {
        try await snapshot().forwarded.first { $0.remotePort == remote }
    }
}

extension PortNotice {
    /// An offer of `port` listening on every address, as `PortsChannel.send` makes it.
    static func listening(port: Int, name: String?) -> PortNotice {
        .listening(RemotePort(port: port, destination: .localhost, name: name))
    }
}
