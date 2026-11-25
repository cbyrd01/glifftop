/// Hand-built wire bytes, as draft-ietf-secsh-filexfer-02 lays them out: big-endian integers,
/// strings as a 4-byte length and their bytes, a packet as a 4-byte length, its type and body.
enum SFTPBytes {
    static func u32(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }

    static func u64(_ value: UInt64) -> [UInt8] {
        u32(UInt32(value >> 32)) + u32(UInt32(value & 0xFFFF_FFFF))
    }

    static func string(_ bytes: [UInt8]) -> [UInt8] { u32(UInt32(bytes.count)) + bytes }

    static func string(_ text: String) -> [UInt8] { string(Array(text.utf8)) }

    static func packet(_ type: UInt8, _ body: [UInt8]) -> [UInt8] {
        u32(UInt32(body.count + 1)) + [type] + body
    }

    /// VERSION 3 with OpenSSH's four extensions at the versions it offers.
    static let version: [UInt8] = packet(
        2,
        u32(3)
            + [
                ("posix-rename@openssh.com", "1"), ("statvfs@openssh.com", "2"), ("fsync@openssh.com", "1"),
                ("limits@openssh.com", "1"),
            ]
            .flatMap { string($0.0) + string($0.1) })
}
