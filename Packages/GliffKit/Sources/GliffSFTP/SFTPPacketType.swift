/// An SFTP v3 packet's type byte (draft-ietf-secsh-filexfer-02, section 3).
public enum SFTPPacketType: UInt8, Sendable {
    case initialize = 1
    case version = 2
    case open = 3
    case close = 4
    case read = 5
    case write = 6
    case lstat = 7
    case fstat = 8
    case setstat = 9
    case fsetstat = 10
    case opendir = 11
    case readdir = 12
    case remove = 13
    case mkdir = 14
    case rmdir = 15
    case realpath = 16
    case stat = 17
    case rename = 18
    case readlink = 19
    case status = 101
    case handle = 102
    case data = 103
    case name = 104
    case attributes = 105
    case extended = 200
    case extendedReply = 201
}
