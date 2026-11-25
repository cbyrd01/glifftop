/// `-L`'s argument for a `PortForward`, built from typed values only: `127.0.0.1:P:dest:port`
/// or `[::1]:P:dest:port`, an IPv6 destination in brackets. No other listen address can be
/// made.
enum SSHForwardSpec {
    static func make(_ forward: PortForward, on loopback: Loopback) -> String {
        let host = forward.destination.host
        let target = host.contains(":") ? "[\(host)]" : host
        return "\(listen(loopback)):\(forward.localPort):\(target):\(forward.remotePort)"
    }

    private static func listen(_ loopback: Loopback) -> String {
        loopback == .ipv4 ? loopback.address : "[\(loopback.address)]"
    }
}
