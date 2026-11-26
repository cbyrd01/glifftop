/// Hand-built wire bytes, as draft-ietf-secsh-filexfer-02 lays them out: big-endian integers,
/// strings as a 4-byte length and their bytes, a packet as a 4-byte length, its type and body.
public enum SFTPBytes {
    public static func u32(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }

    public static func u64(_ value: UInt64) -> [UInt8] {
        u32(UInt32(value >> 32)) + u32(UInt32(value & 0xFFFF_FFFF))
    }

    public static func string(_ bytes: [UInt8]) -> [UInt8] { u32(UInt32(bytes.count)) + bytes }

    public static func string(_ text: String) -> [UInt8] { string(Array(text.utf8)) }

    public static func packet(_ type: UInt8, _ body: [UInt8]) -> [UInt8] {
        u32(UInt32(body.count + 1)) + [type] + body
    }

    /// STATUS: a code, a message and a language tag.
    public static func status(_ id: UInt32, _ code: UInt32, _ message: String = "") -> [UInt8] {
        packet(101, u32(id) + u32(code) + string(message) + string("en"))
    }

    public static func handle(_ id: UInt32, _ handle: [UInt8] = [0, 0, 0, 1]) -> [UInt8] {
        packet(102, u32(id) + string(handle))
    }

    public static func data(_ id: UInt32, _ bytes: [UInt8]) -> [UInt8] {
        packet(103, u32(id) + string(bytes))
    }

    /// ATTRS with no fields, or with only the permissions `mode`.
    public static func attributes(_ id: UInt32, mode: UInt32? = nil) -> [UInt8] {
        packet(105, u32(id) + attributeFields(mode: mode))
    }

    /// The attribute fields: none, or only the permissions `mode`.
    public static func attributeFields(mode: UInt32?) -> [UInt8] {
        mode.map { u32(0x4) + u32($0) } ?? u32(0)
    }

    /// NAME: each entry already laid out as a name, a long name and attributes.
    public static func name(_ id: UInt32, _ entries: [[UInt8]]) -> [UInt8] {
        packet(104, u32(id) + u32(UInt32(entries.count)) + entries.flatMap { $0 })
    }

    /// VERSION 3 with OpenSSH's four extensions at the versions it offers.
    public static let version: [UInt8] = packet(
        2,
        u32(3)
            + [
                ("posix-rename@openssh.com", "1"), ("statvfs@openssh.com", "2"), ("fsync@openssh.com", "1"),
                ("limits@openssh.com", "1"),
            ]
            .flatMap { string($0.0) + string($0.1) })
}
