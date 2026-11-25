import Foundation

/// Whether a port is free on this Mac's loopbacks, found by binding a TCP socket on 127.0.0.1
/// and one on [::1] without `SO_REUSEADDR`, then closing both. ssh's listeners set
/// `SO_REUSEADDR`, which lets them bind `127.0.0.1:P` beside a Mac server on `*:P` and shadow
/// it; this check refuses that port. A port taken between the check and ssh's own bind is
/// caught by ssh's "Port forwarding failed".
public enum LoopbackPorts {
    public enum Availability: Equatable, Sendable {
        case free
        /// Free on 127.0.0.1; this Mac has no ::1 (`EADDRNOTAVAIL`).
        case freeIPv4Only
        case taken
    }

    /// Blocking: up to 250 ms on each loopback when a listener's backlog is full, so a caller
    /// keeps it off the main actor.
    public static func check(_ port: Int) -> Availability {
        guard (1...65535).contains(port), side(.ipv4, port: port) == .free else { return .taken }
        return side(.ipv6, port: port)
    }

    /// A port the kernel hands out on 127.0.0.1 that is also free on ::1 (or this Mac has no
    /// ::1); nil when none can be had.
    public static func pick() -> Int? {
        for _ in 0..<8 {
            guard case .bound(let ipv4, let port) = hold(.ipv4, port: 0) else { return nil }
            close(ipv4)
            if side(.ipv6, port: port) != .taken { return port }
        }
        return nil
    }

    /// `port` on one loopback, `.freeIPv4Only` when the address isn't on this Mac. A bind
    /// refused as in use is taken unless nothing answers there: a connection left in TIME_WAIT
    /// refuses a bind without `SO_REUSEADDR`, though ssh's would succeed.
    private static func side(_ loopback: Loopback, port: Int) -> Availability {
        switch hold(loopback, port: port) {
        case .bound(let descriptor, _):
            close(descriptor)
            return .free
        case .unavailable: return .freeIPv4Only
        case .inUse: return refused(loopback, port: port) ? .free : .taken
        case .failed: return .taken
        }
    }

    private enum Held {
        case bound(Int32, port: Int)
        /// The address isn't on this Mac.
        case unavailable
        case inUse
        case failed
    }

    /// Whether a TCP connection to `loopback`:`port` is refused at once: nothing listens there.
    /// A connect still pending after 250 ms (a listener whose backlog is full drops it) isn't. A
    /// listener there sees a connection that closes at once, without a byte.
    private static func refused(_ loopback: Loopback, port: Int) -> Bool {
        guard let found = address(loopback, port: port) else { return false }
        defer { freeaddrinfo(found) }
        let info = found.pointee
        let descriptor = socket(info.ai_family, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        if connect(descriptor, info.ai_addr, info.ai_addrlen) == 0 { return false }
        if errno == ECONNREFUSED { return true }
        guard errno == EINPROGRESS else { return false }
        var waiting = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        guard poll(&waiting, 1, 250) == 1 else { return false }
        var error: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &size) == 0 else { return false }
        return error == ECONNREFUSED
    }

    /// `loopback`:`port` as a socket address; the caller frees it.
    private static func address(_ loopback: Loopback, port: Int) -> UnsafeMutablePointer<addrinfo>? {
        var hints = addrinfo()
        hints.ai_flags = AI_NUMERICHOST | AI_NUMERICSERV
        hints.ai_socktype = SOCK_STREAM
        var found: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(loopback.address, String(port), &hints, &found) == 0 else { return nil }
        return found
    }

    /// A TCP socket bound on `loopback` at `port` (0: the kernel picks), with no
    /// `SO_REUSEADDR`, an IPv6 one IPv6-only.
    private static func hold(_ loopback: Loopback, port: Int) -> Held {
        guard let found = address(loopback, port: port) else { return .failed }
        defer { freeaddrinfo(found) }
        let info = found.pointee
        let descriptor = socket(info.ai_family, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return .failed }
        var on: Int32 = 1
        if loopback == .ipv6 {
            setsockopt(descriptor, IPPROTO_IPV6, IPV6_V6ONLY, &on, socklen_t(MemoryLayout<Int32>.size))
        }
        var bound = sockaddr_storage()
        var size = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let held = withUnsafeMutablePointer(to: &bound) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, info.ai_addr, info.ai_addrlen) == 0
                    && getsockname(descriptor, $0, &size) == 0
            }
        }
        guard held else {
            let error = errno
            close(descriptor)
            return error == EADDRNOTAVAIL ? .unavailable : error == EADDRINUSE ? .inUse : .failed
        }
        // sockaddr_in and sockaddr_in6 both keep the port, in network order, at byte 2.
        let networkPort = withUnsafeBytes(of: bound) { $0.loadUnaligned(fromByteOffset: 2, as: UInt16.self) }
        return .bound(descriptor, port: Int(UInt16(bigEndian: networkPort)))
    }
}
