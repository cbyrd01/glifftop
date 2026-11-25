import GliffSFTP
import GliffTestSupport
import Testing

/// Each request against the bytes draft-ietf-secsh-filexfer-02 section 6 lays out.
@Suite struct SFTPRequestTests {
    typealias B = SFTPBytes
    static let handle: [UInt8] = [0, 0, 0, 1]
    static let path = Array("/home/person/a".utf8)
    static let other = Array("/home/person/b".utf8)
    static let mode = SFTPAttributes(permissions: 0o600)
    static let modeBytes = B.u32(4) + B.u32(0o600)

    /// INIT has no id: its version stands where an id would.
    @Test func initCarriesTheVersionOnly() {
        #expect(SFTPRequest.initialize.encoded(id: 99) == B.packet(1, B.u32(3)))
    }

    @Test(arguments: [
        (
            SFTPRequest.open(path: path, flags: [.write, .create, .exclusive], attributes: mode),
            B.packet(3, B.u32(7) + B.string(path) + B.u32(0x2A) + modeBytes)
        ),
        (.close(handle: handle), B.packet(4, B.u32(7) + B.string(handle))),
        (
            .read(handle: handle, offset: 1 << 33, length: 32768),
            B.packet(5, B.u32(7) + B.string(handle) + B.u64(1 << 33) + B.u32(32768))
        ),
        (
            .write(handle: handle, offset: 5, data: [1, 2, 3]),
            B.packet(6, B.u32(7) + B.string(handle) + B.u64(5) + B.string([1, 2, 3]))
        ),
        (.lstat(path: path), B.packet(7, B.u32(7) + B.string(path))),
        (.fstat(handle: handle), B.packet(8, B.u32(7) + B.string(handle))),
        (.setstat(path: path, attributes: mode), B.packet(9, B.u32(7) + B.string(path) + modeBytes)),
        (.fsetstat(handle: handle, attributes: mode), B.packet(10, B.u32(7) + B.string(handle) + modeBytes)),
        (.opendir(path: path), B.packet(11, B.u32(7) + B.string(path))),
        (.readdir(handle: handle), B.packet(12, B.u32(7) + B.string(handle))),
        (.remove(path: path), B.packet(13, B.u32(7) + B.string(path))),
        (.mkdir(path: path, attributes: mode), B.packet(14, B.u32(7) + B.string(path) + modeBytes)),
        (.rmdir(path: path), B.packet(15, B.u32(7) + B.string(path))),
        (.realpath(path: [0x2E]), B.packet(16, B.u32(7) + B.string("."))),
        (.stat(path: path), B.packet(17, B.u32(7) + B.string(path))),
        (.rename(from: path, to: other), B.packet(18, B.u32(7) + B.string(path) + B.string(other))),
        (.readlink(path: path), B.packet(19, B.u32(7) + B.string(path))),
        (
            .posixRename(from: path, to: other),
            B.packet(
                200, B.u32(7) + B.string("posix-rename@openssh.com") + B.string(path) + B.string(other))
        ),
        (.statvfs(path: path), B.packet(200, B.u32(7) + B.string("statvfs@openssh.com") + B.string(path))),
        (.fsync(handle: handle), B.packet(200, B.u32(7) + B.string("fsync@openssh.com") + B.string(handle))),
        (.limits, B.packet(200, B.u32(7) + B.string("limits@openssh.com"))),
    ])
    func eachRequestIsEncodedAsTheDraftSays(_ request: SFTPRequest, _ bytes: [UInt8]) {
        #expect(request.encoded(id: 7) == bytes)
    }

    @Test func theOpenFlagsAreTheDrafts() {
        #expect(SFTPOpenFlags.read.rawValue == 1)
        #expect(SFTPOpenFlags.write.rawValue == 2)
        #expect(SFTPOpenFlags.append.rawValue == 4)
        #expect(SFTPOpenFlags.create.rawValue == 8)
        #expect(SFTPOpenFlags.truncate.rawValue == 0x10)
        #expect(SFTPOpenFlags.exclusive.rawValue == 0x20)
    }

    /// A write's bytes travel as one string after the header.
    @Test func aWriteKnowsItsHeaderLength() {
        let request = SFTPRequest.write(
            handle: Self.handle, offset: 0, data: [UInt8](repeating: 1, count: 32768))
        #expect(request.encoded(id: 1).count == 4 + 1 + 4 + 8 + 8 + 4 + 32768)
    }
}
