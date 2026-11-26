import GliffTransport

/// A port a machine forwards when connected: the port on the host, where it goes there
/// (`localhost` or an IP literal), and the Mac port it last used.
public struct SavedForward: Codable, Hashable, Sendable {
    public private(set) var remotePort: Int
    public private(set) var destination: String
    public private(set) var localPort: Int?

    /// Nil unless `remotePort` is a port, `destination` is `localhost` or an IP literal, and
    /// `localPort`, if any, a Mac port a forward can listen on. The destination is kept in one
    /// spelling: `localhost`, or the address as `inet_ntop` writes it.
    public init?(remotePort: Int, destination: String, localPort: Int?) {
        guard 1...65535 ~= remotePort, localPort.map(PortForward.localPorts.contains) ?? true,
            let destination = Self.canonical(destination)
        else { return nil }
        (self.remotePort, self.destination, self.localPort) = (remotePort, destination, localPort)
    }

    /// An entry that isn't a saved forward by `init`'s rules can't be read.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let read = Self(
            remotePort: try container.decode(Int.self, forKey: .remotePort),
            destination: try container.decode(String.self, forKey: .destination),
            localPort: try container.decodeIfPresent(Int.self, forKey: .localPort))
        guard let read else {
            throw DecodingError.dataCorruptedError(
                forKey: .destination, in: container, debugDescription: "not a saved forward")
        }
        self = read
    }

    /// `localhost` in any case, or an IPv4 or IPv6 literal (no brackets, no zone), in its one
    /// spelling; nil for anything else.
    static func canonical(_ text: String) -> String? {
        text.lowercased() == "localhost" ? "localhost" : IPLiteral(text)?.text
    }

    /// `forwards` with each host port and destination once, the first kept.
    static func once(_ forwards: [SavedForward]) -> [SavedForward] {
        var seen = Set<[String]>()
        return forwards.filter { seen.insert([$0.destination, String($0.remotePort)]).inserted }
    }
}
