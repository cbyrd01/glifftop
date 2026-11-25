/// A file's attributes, as v3 carries them: a flags word, then each field it names.
///
/// - Read: size, owner, permissions (with the `S_IFMT` type bits), times, and extended pairs
///   (read and skipped). A flag outside `0x8000000F` throws, since v3 attributes carry no length.
/// - Written: size, permissions and times only. An owner is never sent.
public struct SFTPAttributes: Equatable, Sendable {
    public var size: UInt64?
    public private(set) var uid: UInt32?
    public private(set) var gid: UInt32?
    public var permissions: UInt32?
    public var times: SFTPTimes?

    public init(size: UInt64? = nil, permissions: UInt32? = nil, times: SFTPTimes? = nil) {
        (self.size, self.permissions, self.times) = (size, permissions, times)
    }

    private enum Flag {
        static let size: UInt32 = 0x1
        static let owner: UInt32 = 0x2
        static let permissions: UInt32 = 0x4
        static let times: UInt32 = 0x8
        static let extended: UInt32 = 0x8000_0000
        static let known: UInt32 = 0x8000_000F
    }

    public init(from reader: inout SFTPReader) throws(SFTPError) {
        let flags = try reader.uint32()
        guard flags & ~Flag.known == 0 else { throw .unknownAttributeFlags }
        if flags & Flag.size != 0 { size = try reader.uint64() }
        if flags & Flag.owner != 0 {
            uid = try reader.uint32()
            gid = try reader.uint32()
        }
        if flags & Flag.permissions != 0 { permissions = try reader.uint32() }
        if flags & Flag.times != 0 {
            times = SFTPTimes(access: try reader.uint32(), modification: try reader.uint32())
        }
        if flags & Flag.extended != 0 {
            let count = Int(try reader.uint32())
            guard count <= SFTPReader.maxPairs else { throw .tooManyExtensions }
            for _ in 0..<count * 2 { try reader.skipString() }
        }
    }

    public func write(to writer: inout SFTPWriter) {
        var flags: UInt32 = 0
        if size != nil { flags |= Flag.size }
        if permissions != nil { flags |= Flag.permissions }
        if times != nil { flags |= Flag.times }
        writer.uint32(flags)
        if let size { writer.uint64(size) }
        if let permissions { writer.uint32(permissions) }
        if let times {
            writer.uint32(times.access)
            writer.uint32(times.modification)
        }
    }

    /// The kind of file, from the permissions' `S_IFMT` bits; nil without permissions.
    public var fileType: SFTPFileType? { permissions.map(SFTPFileType.init(mode:)) }
}

/// Access and modification times, seconds since 1970 in 32 bits.
public struct SFTPTimes: Equatable, Sendable {
    public var access: UInt32
    public var modification: UInt32

    public init(access: UInt32, modification: UInt32) {
        (self.access, self.modification) = (access, modification)
    }
}

/// A file's kind, from the `S_IFMT` bits of its mode.
public enum SFTPFileType: Equatable, Sendable {
    case regular, directory, link, fifo, socket, device, unknown

    public init(mode: UInt32) {
        self =
            switch mode & 0o170000 {
            case 0o100000: .regular
            case 0o040000: .directory
            case 0o120000: .link
            case 0o010000: .fifo
            case 0o140000: .socket
            case 0o020000, 0o060000: .device
            default: .unknown
            }
    }
}
