/// `-L`'s argument for a `PortForward`, built from typed values only: `127.0.0.1:P:dest:port`
/// or `[::1]:P:dest:port`, an IPv6 destination in brackets. No other listen address can be
/// made.
enum SSHForwardSpec {
    static func make(_ forward: PortForward, on loopback: Loopback) -> String {
        "\(listen(loopback)):\(forward.localPort):\(forward.destination.bracketedHost):\(forward.remotePort)"
    }

    private static func listen(_ loopback: Loopback) -> String {
        loopback == .ipv4 ? loopback.address : "[\(loopback.address)]"
    }
}
