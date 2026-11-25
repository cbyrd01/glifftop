import Foundation
import GliffTransport

/// One frame, read: `B <nonce> none` is `.unavailable`; `B <nonce> proc <uid> [<lo> <hi>]`
/// is a `PortFrame` of the header's uid and range, the `P` sockets of that uid (at most 64),
/// and their names from the `N` lines that match one exactly; any other header is nothing.
enum PortFrameReader {
    static let maxSockets = 64
    static let defaultEphemeral = 32768...60999
    static let maxName = 32

    /// `header` is the `B` line's words; `lines` follow it, up to the `E` line.
    static func output(header: [Substring], lines: [String]) -> PortListParser.Output? {
        if header.count == 3, header[2] == "none" { return .unavailable }
        return frame(header: header, lines: lines).map(PortListParser.Output.frame)
    }

    static func frame(header: [Substring], lines: [String]) -> PortFrame? {
        // Five words is a range with no uid before it (an empty `$u`).
        guard header.count >= 4, header.count != 5, header[2] == "proc", let uid = Int(header[3]), uid >= 0
        else { return nil }
        var sockets: [ListeningSocket] = []
        var names: [(ListenAddress, String)] = []
        for line in lines {
            // Every socket so far has this uid and no name: equal means the same address and port.
            if line.hasPrefix("P "), sockets.count < maxSockets, let socket = listening(line, uid: uid),
                !sockets.contains(socket)
            {
                sockets.append(socket)
            } else if line.hasPrefix("N "), let named = named(line) {
                names.append(named)
            }
        }
        for index in sockets.indices {
            sockets[index].name = names.first { $0.0.matches(sockets[index]) }?.1
        }
        return PortFrame(uid: uid, ephemeral: ephemeral(header), sockets: sockets)
    }

    /// The header's `<lo> <hi>`, or the default when they aren't two numbers in order.
    private static func ephemeral(_ header: [Substring]) -> ClosedRange<Int> {
        guard header.count == 6, let low = Int(header[4]), let high = Int(header[5]),
            1 <= low, low <= high, high <= 65535
        else { return defaultEphemeral }
        return low...high
    }

    /// `P <hexaddr>:<hexport> <uid>`: the address in the host's byte order, read as
    /// little-endian (gliff-server's hosts are x86_64 and aarch64; IPv6 as four little-endian
    /// words), the port big-endian; another uid's row is dropped.
    static func listening(_ line: String, uid: Int) -> ListeningSocket? {
        let words = line.split(separator: " ", omittingEmptySubsequences: false)
        guard words.count == 3, Int(words[2]) == uid else { return nil }
        let parts = words[1].split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[1].count == 4, isASCIIHex(parts[1]),
            let port = Int(parts[1], radix: 16), port > 0,
            parts[0].count == 8 || parts[0].count == 32, isASCIIHex(parts[0])
        else { return nil }
        // Each 8-digit word is a little-endian 32-bit number: its low byte comes first.
        let hex = Array(parts[0])
        let ordered = stride(from: 0, to: hex.count, by: 8).flatMap { start in
            let word = UInt32(String(hex[start..<start + 8]), radix: 16) ?? 0
            return (0..<4).map { UInt8(truncatingIfNeeded: word >> ($0 * 8)) }
        }
        guard let address = IPLiteral(bytes: ordered) else { return nil }
        return ListeningSocket(address: address, port: port, uid: uid)
    }

    private static func isASCIIHex(_ text: Substring) -> Bool {
        text.allSatisfy { $0.isASCII && $0.isHexDigit }
    }

    /// `N LISTEN <local> <peer> users:(("<name>",pid=...`: the local address and the name, or
    /// nil for any other shape, a zoned address, or no name.
    static func named(_ line: String) -> (ListenAddress, String)? {
        let words = line.split(whereSeparator: \.isWhitespace)
        guard words.count >= 5, words[1] == "LISTEN", words[4].hasPrefix("users:(("),
            let local = ListenAddress(words[2]),
            let start = line.range(of: "users:((\""),
            let end = line.range(of: "\",pid=", range: start.upperBound..<line.endIndex),
            let name = clean(line[start.upperBound..<end.lowerBound])
        else { return nil }
        return (local, name)
    }

    /// What a name never shows: what remote text never shows, and private or unassigned scalars.
    static let hidden = SSHErrorClassifier.hidden.union([.privateUse, .unassigned])

    /// Printable characters only, no bidirectional or other format controls, at most 32; nil
    /// when nothing is left.
    static func clean(_ text: Substring) -> String? {
        let kept = String(
            String.UnicodeScalarView(
                text.unicodeScalars.filter { !hidden.contains($0.properties.generalCategory) }))
        let cut = String(kept.prefix(maxName))
        return cut.isEmpty ? nil : cut
    }
}

/// An `ss` local address and port: `127.0.0.1:631`, `*:80`, `[::]:22`, `[::1]:631`,
/// `[::ffff:127.0.0.1]:8080`. A zoned one isn't read.
struct ListenAddress: Equatable {
    /// nil for `*`, which is either wildcard.
    let address: IPLiteral?
    let port: Int

    init?(_ text: Substring) {
        guard let colon = text.lastIndex(of: ":"), let port = Int(text[text.index(after: colon)...]),
            (1...65535).contains(port)
        else { return nil }
        var host = text[..<colon]
        if host == "*" {
            address = nil
        } else {
            if host.hasPrefix("["), host.hasSuffix("]") { host = host.dropFirst().dropLast() }
            guard let literal = IPLiteral(String(host)) else { return nil }
            address = literal
        }
        self.port = port
    }

    func matches(_ socket: ListeningSocket) -> Bool {
        guard port == socket.port else { return false }
        return address.map { $0 == socket.address } ?? socket.isWildcard
    }
}
