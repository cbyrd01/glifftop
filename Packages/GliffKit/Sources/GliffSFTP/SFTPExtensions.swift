/// The OpenSSH extensions a VERSION offered, of those Glifftop uses.
public struct SFTPExtensions: Equatable, Sendable {
    /// `posix-rename@openssh.com`: a rename that replaces (Replace).
    public var posixRename = false
    /// `statvfs@openssh.com`: a volume's free space.
    public var statvfs = false
    /// `fsync@openssh.com`: an open file flushed to disk.
    public var fsync = false
    /// `limits@openssh.com`: the server's read, write and open-handle limits.
    public var limits = false

    public init() {}

    static let posixRenameName = "posix-rename@openssh.com"
    static let statvfsName = "statvfs@openssh.com"
    static let fsyncName = "fsync@openssh.com"
    static let limitsName = "limits@openssh.com"

    /// Turns on the extension `name`, if it is one of these at the version whose reply is
    /// decoded here (statvfs "2", the others "1").
    mutating func offer(_ name: [UInt8], version: [UInt8]) {
        let one = version.elementsEqual("1".utf8)
        if name.elementsEqual(Self.posixRenameName.utf8) { posixRename = one }
        if name.elementsEqual(Self.statvfsName.utf8) { statvfs = version.elementsEqual("2".utf8) }
        if name.elementsEqual(Self.fsyncName.utf8) { fsync = one }
        if name.elementsEqual(Self.limitsName.utf8) { limits = one }
    }
}

/// A `statvfs@openssh.com` reply: a volume's sizes.
public struct SFTPSpace: Equatable, Sendable {
    public var blockSize: UInt64
    public var fragmentSize: UInt64
    public var availableBlocks: UInt64

    public init(blockSize: UInt64, fragmentSize: UInt64, availableBlocks: UInt64) {
        (self.blockSize, self.fragmentSize, self.availableBlocks) = (blockSize, fragmentSize, availableBlocks)
    }

    /// The bytes free to an unprivileged user, saturating; blocks count in the fragment size,
    /// or the block size when a server leaves that 0.
    public var availableBytes: UInt64 {
        let unit = fragmentSize == 0 ? blockSize : fragmentSize
        let (product, overflow) = unit.multipliedReportingOverflow(by: availableBlocks)
        return overflow ? .max : product
    }

    /// Reads the reply's eleven numbers: block size, fragment size, blocks, free, available, …
    public static func decode(_ body: [UInt8]) throws(SFTPError) -> SFTPSpace {
        var reader = SFTPReader(body)
        let blockSize = try reader.uint64()
        let fragmentSize = try reader.uint64()
        for _ in 0..<2 { _ = try reader.uint64() }
        let availableBlocks = try reader.uint64()
        for _ in 0..<6 { _ = try reader.uint64() }
        return SFTPSpace(blockSize: blockSize, fragmentSize: fragmentSize, availableBlocks: availableBlocks)
    }
}

/// A `limits@openssh.com` reply. Zero means no limit.
public struct SFTPLimits: Equatable, Sendable {
    public var packetLength: UInt64
    public var readLength: UInt64
    public var writeLength: UInt64
    public var openHandles: UInt64

    public init(packetLength: UInt64, readLength: UInt64, writeLength: UInt64, openHandles: UInt64) {
        (self.packetLength, self.readLength, self.writeLength, self.openHandles) =
            (packetLength, readLength, writeLength, openHandles)
    }

    /// The most a READ or WRITE carries: sftp-server's own limit (256 KiB less 1 KiB), which
    /// fits a packet `SFTPFramer` takes.
    public static let maxChunk: UInt64 = 255 * 1024

    /// The length to ask a READ for: the server's limit, at most `maxChunk`; `maxChunk` when
    /// the server names none (0).
    public var readChunk: UInt32 { Self.chunk(readLength) }

    /// The most one WRITE carries, as `readChunk`.
    public var writeChunk: UInt32 { Self.chunk(writeLength) }

    private static func chunk(_ limit: UInt64) -> UInt32 {
        UInt32(limit == 0 ? maxChunk : min(limit, maxChunk))
    }

    public static func decode(_ body: [UInt8]) throws(SFTPError) -> SFTPLimits {
        var reader = SFTPReader(body)
        return SFTPLimits(
            packetLength: try reader.uint64(), readLength: try reader.uint64(),
            writeLength: try reader.uint64(),
            openHandles: try reader.uint64())
    }
}
