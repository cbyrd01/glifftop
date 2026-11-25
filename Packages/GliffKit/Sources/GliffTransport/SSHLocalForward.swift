/// A `LocalForward` from the person's ssh_config, which Glifftop adds to its master itself, on
/// 127.0.0.1 only: the config's bind address is never used (`localhost`, or none, lets ssh
/// bind ::1 alone and report success while another program holds 127.0.0.1).
///
/// Read from `ssh -G`'s `localforward` line: the listen side is `port` or `[address]:port`,
/// the target `[host]:port`. A unix socket on either side (a path, with `/`) isn't one.
public struct SSHLocalForward: Equatable, Sendable {
    /// The port on the Mac's 127.0.0.1.
    public var port: Int
    /// Where the host connects, as the config names it.
    public var host: String
    public var hostPort: Int

    public init(port: Int, host: String, hostPort: Int) {
        (self.port, self.host, self.hostPort) = (port, host, hostPort)
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
        self.init(port: port, host: String(host), hostPort: hostPort)
    }

    /// `-L`'s argument: `127.0.0.1:port:host:hostPort`, an IPv6 host in brackets.
    var argument: String {
        let target = host.contains(":") ? "[\(host)]" : host
        return "127.0.0.1:\(port):\(target):\(hostPort)"
    }

    private static func port(_ text: (some StringProtocol)?) -> Int? {
        guard let text, let port = Int(text), (1...65535).contains(port) else { return nil }
        return port
    }
}
