/// One entry of a NAME reply. Its `longname` (the `ls -l` text) is read past, never kept.
public struct SFTPNameEntry: Equatable, Sendable {
    public var name: [UInt8]
    public var attributes: SFTPAttributes

    public init(name: [UInt8], attributes: SFTPAttributes) {
        (self.name, self.attributes) = (name, attributes)
    }
}

/// Every reply the host may send, decoded under the limits on host input: a STATUS keeps its
/// code only, never its message; a name is at most 4 KiB; a NAME's count must fit its bytes.
public enum SFTPReply: Equatable, Sendable {
    case version(SFTPExtensions)
    case status(id: UInt32, code: SFTPStatusCode)
    case handle(id: UInt32, handle: [UInt8])
    case data(id: UInt32, bytes: [UInt8])
    case name(id: UInt32, entries: [SFTPNameEntry])
    case attributes(id: UInt32, SFTPAttributes)
    /// The body after the id, read by whoever sent the request (`SFTPSpace`, `SFTPLimits`).
    case extendedReply(id: UInt32, body: [UInt8])

    /// The fewest bytes a NAME entry takes: two empty strings and a flags word.
    static let minNameEntry = 12

    /// The request it answers; nil for VERSION.
    public var id: UInt32? {
        switch self {
        case .version: nil
        case .status(let id, _), .handle(let id, _), .data(let id, _), .name(let id, _),
            .attributes(let id, _),
            .extendedReply(let id, _):
            id
        }
    }

    public static func decode(_ packet: SFTPPacket) throws(SFTPError) -> SFTPReply {
        var reader = SFTPReader(packet.body)
        if packet.type == SFTPPacketType.version.rawValue { return .version(try extensions(&reader)) }
        let id = try reader.uint32()
        switch SFTPPacketType(rawValue: packet.type) {
        case .status:
            let code = SFTPStatusCode(try reader.uint32())
            return .status(id: id, code: code)
        case .handle: return .handle(id: id, handle: try reader.string())
        case .data: return .data(id: id, bytes: try reader.string(max: SFTPFramer.maxPacketLength))
        case .name: return .name(id: id, entries: try names(&reader))
        case .attributes: return .attributes(id: id, try SFTPAttributes(from: &reader))
        case .extendedReply: return .extendedReply(id: id, body: reader.rest())
        default: throw .unexpectedType(packet.type)
        }
    }

    private static func extensions(_ reader: inout SFTPReader) throws(SFTPError) -> SFTPExtensions {
        guard try reader.uint32() == SFTPRequest.version else { throw .unsupportedVersion }
        var extensions = SFTPExtensions()
        var count = 0
        while !reader.isAtEnd {
            count += 1
            guard count <= SFTPReader.maxPairs else { throw .tooManyExtensions }
            let name = try reader.string()
            extensions.offer(name, version: try reader.string())
        }
        return extensions
    }

    private static func names(_ reader: inout SFTPReader) throws(SFTPError) -> [SFTPNameEntry] {
        let count = Int(try reader.uint32())
        guard count <= reader.remaining / minNameEntry else { throw .nameCountTooLarge }
        var entries: [SFTPNameEntry] = []
        entries.reserveCapacity(count)
        for _ in 0..<count {
            let name = try reader.string()
            try reader.skipString()
            entries.append(SFTPNameEntry(name: name, attributes: try SFTPAttributes(from: &reader)))
        }
        return entries
    }
}
