/// One packet: its type byte and the bytes after it.
public struct SFTPPacket: Equatable, Sendable {
    public let type: UInt8
    public let body: [UInt8]

    public init(type: UInt8, body: [UInt8]) {
        (self.type, self.body) = (type, body)
    }
}

/// Cuts the host's byte stream into packets: a 4-byte length, then the type and the body.
///
/// - A packet longer than `maxPacketLength`, or shorter than a type and an id (five bytes),
///   throws.
/// - Until a VERSION has come, any broken rule, or a first packet of another type, throws
///   `.textBeforeVersion`: a login shell that prints text before the server starts.
/// - A chunk that breaks a rule throws, and the packets cut before it in that chunk are
///   dropped: the session ends, failing every request still waiting.
public struct SFTPFramer: Sendable {
    /// sftp-server's own maximum, 256 KiB, and 1 KiB for its header.
    public static let maxPacketLength = 256 * 1024 + 1024

    private var buffer: [UInt8] = []
    /// Where the unread bytes in `buffer` start.
    private var start = 0
    private var sawVersion = false

    public init() {}

    public mutating func feed(_ bytes: [UInt8]) throws(SFTPError) -> [SFTPPacket] {
        buffer += bytes
        var packets: [SFTPPacket] = []
        do {
            while let packet = try next() { packets.append(packet) }
        } catch {
            throw beforeVersion(or: error)
        }
        if start > 0, start * 2 >= buffer.count {
            buffer.removeFirst(start)
            start = 0
        }
        return packets
    }

    /// The stream ended: bytes left unread are a login shell's text before VERSION, or a packet
    /// cut short after it.
    public func finish() throws(SFTPError) {
        guard start < buffer.count else { return }
        throw beforeVersion(or: .truncated)
    }

    /// Any broken rule before VERSION is a login shell's text.
    private func beforeVersion(or error: SFTPError) -> SFTPError {
        sawVersion ? error : .textBeforeVersion
    }

    private mutating func next() throws(SFTPError) -> SFTPPacket? {
        guard buffer.count - start >= 4 else { return nil }
        let length = buffer[start..<start + 4].reduce(0) { $0 << 8 | Int($1) }
        if length > Self.maxPacketLength { throw .packetTooLong }
        if length < 5 { throw .packetTooShort }
        guard buffer.count - start >= 4 + length else { return nil }
        let type = buffer[start + 4]
        if !sawVersion {
            guard type == SFTPPacketType.version.rawValue else { throw .textBeforeVersion }
            sawVersion = true
        }
        let packet = SFTPPacket(type: type, body: Array(buffer[start + 5..<start + 4 + length]))
        start += 4 + length
        return packet
    }
}
