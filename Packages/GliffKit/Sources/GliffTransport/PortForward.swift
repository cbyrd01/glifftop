import Foundation

/// A forward from this Mac's loopback to the host: connections to `localPort` on the Mac are
/// carried to `destination` at `remotePort`, seen from the host. There is no bind address: a
/// forward listens on 127.0.0.1 and ::1 only (`Loopback`).
public struct PortForward: Hashable, Sendable {
    /// 1024–65535: no forward takes a privileged port on the Mac.
    public let localPort: Int
    public let destination: ForwardDestination
    /// 1–65535.
    public let remotePort: Int

    public init?(localPort: Int, destination: ForwardDestination, remotePort: Int) {
        guard (1024...65535).contains(localPort), (1...65535).contains(remotePort) else { return nil }
        (self.localPort, self.destination, self.remotePort) = (localPort, destination, remotePort)
    }
}

/// Where the host connects for a forward: itself, an address it can reach, or a host name the
/// person's own ssh_config gave.
public enum ForwardDestination: Hashable, Sendable {
    case localhost
    case address(IPLiteral)
    /// Only from the ssh_config's `LocalForward` lines (`init?(configuredHost:)`).
    case configured(ConfiguredHost)

    /// A config's host as `ssh -G` printed it, unbracketed: "localhost", in any case, is
    /// `.localhost`; an IP literal is an `.address`; otherwise a name, non-empty, with no NUL,
    /// whitespace, `/` (a unix socket), brackets, `:` or `%`. It is only ever one argv element,
    /// never shell text.
    public init?(configuredHost: String) {
        if configuredHost.lowercased() == "localhost" {
            self = .localhost
            return
        }
        if let literal = IPLiteral(configuredHost) {
            self = .address(literal)
            return
        }
        guard let host = ConfiguredHost(configuredHost) else { return nil }
        self = .configured(host)
    }

    /// The host as ssh's `-L` names it, unbracketed.
    public var host: String {
        switch self {
        case .localhost: "localhost"
        case .address(let literal): literal.text
        case .configured(let host): host.name
        }
    }
}

/// A host name from the person's ssh_config, checked: non-empty, no NUL, whitespace, `/`,
/// brackets, `:` or `%`.
public struct ConfiguredHost: Hashable, Sendable {
    public let name: String

    init?(_ name: String) {
        guard !name.isEmpty, !name.contains(where: { $0.isWhitespace || "\0/[]:%".contains($0) }) else {
            return nil
        }
        self.name = name
    }
}

/// An IPv4 or IPv6 address, parsed (dotted quad, or IPv6 without a zone).
public struct IPLiteral: Hashable, Sendable {
    /// 4 bytes for IPv4, 16 for IPv6, in network order.
    public let bytes: [UInt8]

    public init?(_ text: String) {
        // Darwin's inet_pton takes a zone (`%lo0`): only hex digits, colons and dots get there.
        guard text.allSatisfy({ $0.isASCII && ($0.isHexDigit || $0 == ":" || $0 == ".") }) else { return nil }
        let family = text.contains(":") ? AF_INET6 : AF_INET
        var buffer = [UInt8](repeating: 0, count: family == AF_INET ? 4 : 16)
        guard inet_pton(family, text, &buffer) == 1 else { return nil }
        bytes = buffer
    }

    /// 4 bytes (IPv4) or 16 (IPv6), in network order.
    public init?(bytes: [UInt8]) {
        guard bytes.count == 4 || bytes.count == 16 else { return nil }
        self.bytes = bytes
    }

    /// The canonical text, as `inet_ntop` writes it.
    public var text: String {
        var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        _ = inet_ntop(isIPv6 ? AF_INET6 : AF_INET, bytes, &text, socklen_t(text.count))
        return String(decoding: text.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    public var isIPv6: Bool { bytes.count == 16 }

    /// 127.0.0.0/8, ::1, or ::ffff:127.0.0.0/104.
    public var isLoopback: Bool {
        if !isIPv6 { return bytes[0] == 127 }
        if bytes == Self.ipv6Loopback { return true }
        return bytes.starts(with: Self.mappedPrefix) && bytes[12] == 127
    }

    private static let ipv6Loopback = [UInt8](repeating: 0, count: 15) + [1]
    private static let mappedPrefix = [UInt8](repeating: 0, count: 10) + [0xff, 0xff]
}

/// One of this Mac's loopback addresses, which a forward listens on.
public enum Loopback: Sendable {
    /// 127.0.0.1.
    case ipv4
    /// ::1.
    case ipv6

    /// The address, numeric and unbracketed.
    var address: String { self == .ipv4 ? "127.0.0.1" : "::1" }
}

/// What a forward holds: both loopbacks, or 127.0.0.1 alone (::1 unavailable, or taken
/// between the check and the forward).
public enum Loopbacks: Sendable {
    case both
    case ipv4Only
}

/// Why a forward or a cancel failed.
public enum ForwardError: Error, Equatable, Sendable {
    /// The local port is in use, or refused.
    case localPortInUse
    /// The connection has ended; its forwards ended with it.
    case connectionLost
    /// No answer in time; the forward may still have been made.
    case timedOut
    case failed
}

/// A `LocalForward` from the person's ssh_config: the forward, and the bind address as the
/// config wrote it (display only: every forward binds loopback).
public struct ConfiguredForward: Hashable, Sendable {
    public let forward: PortForward
    public let bind: String?

    public init(forward: PortForward, bind: String?) {
        (self.forward, self.bind) = (forward, bind)
    }
}

/// The ssh_config's forwards for a connection: those Glifftop applies, and the lines it
/// doesn't (as `ssh -G` printed them, display only, never logged).
public struct ConfiguredForwards: Equatable, Sendable {
    public var local: [ConfiguredForward]
    public var notApplied: [String]

    public init(local: [ConfiguredForward], notApplied: [String]) {
        (self.local, self.notApplied) = (local, notApplied)
    }

    public static let none = ConfiguredForwards(local: [], notApplied: [])
}
