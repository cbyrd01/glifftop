public import Foundation
public import GliffTransport

/// The addresses and destinations as the popover shows, opens and copies them.
extension Loopbacks {
    /// Where a forward on Mac port `port` listens: `localhost:P` on both loopbacks,
    /// `127.0.0.1:P` on IPv4 alone.
    public func address(_ port: Int) -> String { "\(self == .both ? "localhost" : "127.0.0.1"):\(port)" }
}

extension ForwardDestination {
    /// `port` there as a row shows it: the number alone on the host itself, else `host:port`.
    public func shown(_ port: Int) -> String { self == .localhost ? "\(port)" : "\(bracketedHost):\(port)" }
}

extension ForwardRow {
    /// Its Mac address: where it listens, else the port it asks for.
    public var localAddress: String? {
        if case .active(let local, let loopbacks) = state { return loopbacks.address(local) }
        return localPort.map(Loopbacks.both.address)
    }

    /// The page an active forward serves, for Open.
    public var url: URL? {
        guard case .active(let local, let loopbacks) = state else { return nil }
        return URL(string: "http://\(loopbacks.address(local))")
    }

    public var shownDestination: String { destination.shown(remotePort) }
}

extension RemotePort {
    public var shownDestination: String { destination.shown(port) }
}

extension PortsSnapshot {
    /// Forward `id`'s row, if it is still forwarded.
    public func forward(_ id: ForwardID) -> ForwardRow? { forwarded.first { $0.id == id } }
}
