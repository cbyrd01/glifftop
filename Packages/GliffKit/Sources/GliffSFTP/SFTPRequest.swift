/// OPEN's flags (draft-ietf-secsh-filexfer-02, section 6.3).
public struct SFTPOpenFlags: OptionSet, Hashable, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let read = SFTPOpenFlags(rawValue: 0x1)
    public static let write = SFTPOpenFlags(rawValue: 0x2)
    public static let append = SFTPOpenFlags(rawValue: 0x4)
    public static let create = SFTPOpenFlags(rawValue: 0x8)
    public static let truncate = SFTPOpenFlags(rawValue: 0x10)
    public static let exclusive = SFTPOpenFlags(rawValue: 0x20)
}

/// Every request Glifftop sends. Paths, names and handles are bytes, never text. SYMLINK is
/// missing on purpose: Glifftop never makes a link.
public enum SFTPRequest: Equatable, Sendable {
    case initialize
    case open(path: [UInt8], flags: SFTPOpenFlags, attributes: SFTPAttributes)
    case close(handle: [UInt8])
    /// `length` is the caller's to keep within `SFTPLimits.readChunk`.
    case read(handle: [UInt8], offset: UInt64, length: UInt32)
    /// `data` is the caller's to keep within `SFTPLimits.writeChunk`: sftp-server ends on a
    /// packet over 256 KiB.
    case write(handle: [UInt8], offset: UInt64, data: [UInt8])
    case lstat(path: [UInt8])
    case fstat(handle: [UInt8])
    case setstat(path: [UInt8], attributes: SFTPAttributes)
    case fsetstat(handle: [UInt8], attributes: SFTPAttributes)
    case opendir(path: [UInt8])
    case readdir(handle: [UInt8])
    case remove(path: [UInt8])
    case mkdir(path: [UInt8], attributes: SFTPAttributes)
    case rmdir(path: [UInt8])
    case realpath(path: [UInt8])
    case stat(path: [UInt8])
    case rename(from: [UInt8], to: [UInt8])
    case readlink(path: [UInt8])
    /// `posix-rename@openssh.com`: replaces `to`.
    case posixRename(from: [UInt8], to: [UInt8])
    /// `statvfs@openssh.com`.
    case statvfs(path: [UInt8])
    /// `fsync@openssh.com`.
    case fsync(handle: [UInt8])
    /// `limits@openssh.com`.
    case limits

    /// The protocol version INIT asks for.
    public static let version: UInt32 = 3

    /// The packet, length first. INIT has no id: `id` is ignored for it.
    public func encoded(id: UInt32) -> [UInt8] {
        var writer = SFTPWriter()
        if case .initialize = self {
            writer.byte(SFTPPacketType.initialize.rawValue)
            writer.uint32(Self.version)
            return writer.packet()
        }
        writer.byte(type.rawValue)
        writer.uint32(id)
        writeFields(to: &writer)
        return writer.packet()
    }

    private var type: SFTPPacketType {
        switch self {
        case .initialize: .initialize
        case .open: .open
        case .close: .close
        case .read: .read
        case .write: .write
        case .lstat: .lstat
        case .fstat: .fstat
        case .setstat: .setstat
        case .fsetstat: .fsetstat
        case .opendir: .opendir
        case .readdir: .readdir
        case .remove: .remove
        case .mkdir: .mkdir
        case .rmdir: .rmdir
        case .realpath: .realpath
        case .stat: .stat
        case .rename: .rename
        case .readlink: .readlink
        case .posixRename, .statvfs, .fsync, .limits: .extended
        }
    }

    private func writeFields(to writer: inout SFTPWriter) {
        switch self {
        case .initialize: break
        case .limits: writer.string(SFTPExtensions.limitsName)
        case .open(let path, let flags, let attributes):
            writer.string(path)
            writer.uint32(flags.rawValue)
            attributes.write(to: &writer)
        case .close(let handle), .fstat(let handle), .readdir(let handle):
            writer.string(handle)
        case .read(let handle, let offset, let length):
            writer.string(handle)
            writer.uint64(offset)
            writer.uint32(length)
        case .write(let handle, let offset, let data):
            writer.string(handle)
            writer.uint64(offset)
            writer.string(data)
        case .lstat(let path), .opendir(let path), .remove(let path), .rmdir(let path), .realpath(let path),
            .stat(let path), .readlink(let path):
            writer.string(path)
        case .setstat(let path, let attributes), .mkdir(let path, let attributes):
            writer.string(path)
            attributes.write(to: &writer)
        case .fsetstat(let handle, let attributes):
            writer.string(handle)
            attributes.write(to: &writer)
        case .rename(let from, let to):
            writer.string(from)
            writer.string(to)
        case .posixRename(let from, let to):
            writer.string(SFTPExtensions.posixRenameName)
            writer.string(from)
            writer.string(to)
        case .statvfs(let path):
            writer.string(SFTPExtensions.statvfsName)
            writer.string(path)
        case .fsync(let handle):
            writer.string(SFTPExtensions.fsyncName)
            writer.string(handle)
        }
    }
}
