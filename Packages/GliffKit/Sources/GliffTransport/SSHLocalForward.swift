/// A `LocalForward` from the person's ssh_config, which Glifftop adds to its master itself, on
/// a loopback it names: the config's bind address is kept for display only (`localhost`, or
/// none, lets ssh bind ::1 alone and report success while another program holds 127.0.0.1).
///
/// Read from `ssh -G`'s `localforward` line: the listen side is `port` or `[address]:port`,
/// the target `[host]:port`. A unix socket on either side (a path, with `/`) isn't one.
public struct SSHLocalForward: Equatable, Sendable {
    /// The port on the Mac's loopback.
    public var port: Int
    /// Where the host connects, as the config names it.
    public var host: String
    public var hostPort: Int
    /// The listen address as `ssh -G` wrote it, unbracketed (`*`, `127.0.0.1`); nil when the
    /// config gave none. Never used to listen.
    public var bind: String?

    public init(port: Int, host: String, hostPort: Int, bind: String? = nil) {
        (self.port, self.host, self.hostPort, self.bind) = (port, host, hostPort, bind)
    }

    /// `value` is what follows `localforward` in `ssh -G`'s output; nil for a unix socket or
    /// text it can't read.
    init?(resolved value: some StringProtocol) {
        let sides = value.split(separator: " ")
        guard sides.count == 2, !sides.contains(where: { $0.contains("/") }),
            let port = Self.port(sides[0].split(separator: ":").last),
            let colon = sides[1].lastIndex(of: ":"),
            let hostPort = Self.port(sides[1][sides[1].index(after: colon)...])
        else { return nil }
        var host = sides[1][..<colon]
        if host.hasPrefix("[") {
            guard host.hasSuffix("]") else { return nil }
            host = host.dropFirst().dropLast()
        }
        guard !host.isEmpty else { return nil }
        let listen = sides[0]
        let bind = listen.lastIndex(of: ":").map { listen[..<$0] }.map {
            $0.hasPrefix("[") && $0.hasSuffix("]") ? $0.dropFirst().dropLast() : $0
        }
        self.init(port: port, host: String(host), hostPort: hostPort, bind: bind.map { String($0) })
    }

    /// The forward as `HostConnection` names it; nil for a local port under 1024 or a
    /// destination a `PortForward` can't hold (an IPv6 zone, a path, brackets).
    var configured: ConfiguredForward? {
        guard let destination = ForwardDestination(configuredHost: host),
            let forward = PortForward(localPort: port, destination: destination, remotePort: hostPort)
        else { return nil }
        return ConfiguredForward(forward: forward, bind: bind)
    }

    private static func port(_ text: (some StringProtocol)?) -> Int? {
        guard let text, let port = Int(text), (1...65535).contains(port) else { return nil }
        return port
    }
}
