import Foundation
import Testing

@testable import GliffFiles

@Suite struct LocalFilesTests {
    @Test func aLocalFIFOIsNotOpenedForReading() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let fifo = folder.url.appending(path: "pipe")
        #expect(mkfifo(fifo.path(percentEncoded: false), 0o600) == 0)
        #expect(try LocalFiles.openForReading(fifo) == nil)
    }

    @Test func aSocketIsNotOpenedForReading() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let (url, descriptor) = try folder.socket("s")
        defer { close(descriptor) }
        #expect(try LocalFiles.openForReading(url) == nil)
    }

    @Test func aStemNeverLeavesItsFolder() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let url = LocalFiles.temporaryURL(in: folder.url, stem: "a/b\u{0}c")
        #expect(
            url.deletingLastPathComponent().path(percentEncoded: false)
                == folder.url.path(percentEncoded: false))
        #expect(url.lastPathComponent.hasPrefix(".a_b_c.glifftop-"))
    }

    @Test func aFolderIsNotOpenedForReading() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        #expect(try LocalFiles.openForReading(folder.url) == nil)
    }

    @Test func aLinkIsNotFollowed() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let file = try folder.file("report.pdf", "bytes")
        let link = folder.url.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(try LocalFiles.openForReading(link) == nil)
        let opened = try #require(try LocalFiles.openForReading(file))
        #expect(opened.size == 5)
        #expect(try opened.read(at: 1, count: 10) == Array("ytes".utf8))
        // A temporary is never created through a link, even a dangling one.
        let dangling = folder.url.appending(path: "dangling")
        try FileManager.default.createSymbolicLink(
            at: dangling, withDestinationURL: folder.url.appending(path: "nowhere"))
        #expect(throws: FilesError.local(.nameTaken)) { try LocalFiles.createTemporaryFile(at: dangling) }
        #expect(!FileManager.default.fileExists(atPath: folder.url.appending(path: "nowhere").path))
    }

    @Test func theTemporaryIs0600UntilFinished() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let url = LocalFiles.temporaryURL(in: folder.url, stem: "report.pdf")
        #expect(url.lastPathComponent.wholeMatch(of: /\.report\.pdf\.glifftop-[0-9a-f]{8}/) != nil)
        let file = try LocalFiles.createTemporaryFile(at: url)
        #expect(TemporaryFolder.status(url).st_mode & 0o7777 == 0o600)
        try file.write(Array("hello".utf8), at: 0)
        try file.write(Array("!".utf8), at: 5)
        try file.finish(mode: 0o4755, modified: 1_700_000_000)
        let status = TemporaryFolder.status(url)
        #expect(status.st_mode & 0o7777 == 0o755)
        #expect(status.st_mtimespec.tv_sec == 1_700_000_000)
        #expect(status.st_atimespec.tv_sec == 1_700_000_000)
        #expect(try Data(contentsOf: url) == Data("hello!".utf8))
    }

    @Test func theTemporaryFolderIs0700UntilFinished() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let url = LocalFiles.temporaryURL(in: folder.url, stem: "photos")
        try LocalFiles.makeTemporaryFolder(at: url)
        #expect(TemporaryFolder.status(url).st_mode & 0o7777 == 0o700)
        try LocalFiles.finishFolder(url, mode: 0o2775, modified: 1_600_000_000)
        #expect(TemporaryFolder.status(url).st_mode & 0o7777 == 0o755)
        #expect(TemporaryFolder.status(url).st_mtimespec.tv_sec == 1_600_000_000)
    }

    @Test func aLongNameFitsIn255Bytes() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let url = LocalFiles.temporaryURL(in: folder.url, stem: String(repeating: "\u{E9}", count: 200))
        let name = url.lastPathComponent
        #expect(name.utf8.count <= 255)
        #expect(name.utf8.count > 250)
        #expect(name.wholeMatch(of: /\.\u{E9}+\.glifftop-[0-9a-f]{8}/) != nil)
        _ = try LocalFiles.createTemporaryFile(at: url)
    }

    @Test func moveInNeverReplacesWithoutReplace() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let existing = try folder.file("report.pdf", "old")
        let url = LocalFiles.temporaryURL(in: folder.url, stem: "report.pdf")
        try LocalFiles.createTemporaryFile(at: url).write(Array("new".utf8), at: 0)
        #expect(throws: FilesError.local(.nameTaken)) {
            try LocalFiles.moveIn(url, as: "report.pdf", replacing: false)
        }
        #expect(try Data(contentsOf: existing) == Data("old".utf8))
        #expect(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
        try LocalFiles.moveIn(url, as: "report.pdf", replacing: true)
        #expect(try Data(contentsOf: existing) == Data("new".utf8))
        #expect(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
    }

    @Test(arguments: ["", ".", "..", "a/b", "a\u{0}b"])
    func moveInRefusesAnUnusableName(name: String) throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let url = LocalFiles.temporaryURL(in: folder.url, stem: "x")
        _ = try LocalFiles.createTemporaryFile(at: url)
        #expect(throws: FilesError.local(.failure)) { try LocalFiles.moveIn(url, as: name, replacing: true) }
        #expect(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
    }

    @Test func modesAreMaskedAndOwnerBitsAdded() {
        #expect(FileMetadata.mode(0o4777, isFolder: false) == 0o755)
        #expect(FileMetadata.mode(0o640, isFolder: false) == 0o640)
        #expect(FileMetadata.mode(0, isFolder: false) == 0o600)
        #expect(FileMetadata.mode(0, isFolder: true) == 0o700)
        #expect(FileMetadata.mode(0o7644, isFolder: true) == 0o744)
    }

    @Test func timesAreClamped() {
        #expect(FileMetadata.time(-5) == 0)
        #expect(FileMetadata.time(1_700_000_000) == 1_700_000_000)
        #expect(FileMetadata.time(Int64(UInt32.max) + 1) == UInt32.max)
    }

    @Test func freeSpaceIsKnown() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        #expect((LocalFiles.freeSpace(at: folder.url) ?? 0) > 0)
    }

    @Test func errorsAreSaidAsThisMacs() {
        #expect(LocalFailure(errno: ENOSPC) == .noSpace)
        #expect(LocalFailure(errno: EACCES) == .permissionDenied)
        #expect(LocalFailure(error: POSIXError(.ENOENT)) == .noSuchFile)
        #expect(LocalFailure(error: CocoaError(.fileWriteOutOfSpace)) == .noSpace)
        #expect(LocalFailure(error: CocoaError(.fileReadUnknown)) == .failure)
        #expect(LocalFailure(error: CocoaError(.fileWriteVolumeReadOnly)) == .permissionDenied)
        #expect(LocalFailure(error: CocoaError(.fileReadNoPermission)) == .permissionDenied)
        #expect(LocalFailure(error: CocoaError(.fileReadNoSuchFile)) == .noSuchFile)
        #expect(LocalFailure(error: CocoaError(.fileWriteFileExists)) == .nameTaken)
        #expect(
            LocalFailure(
                error: CocoaError(.fileWriteUnknown, userInfo: [NSUnderlyingErrorKey: POSIXError(.EACCES)]))
                == .permissionDenied)
        #expect(
            FilesError.local(.noSpace).message(host: "omarchy")
                == "There isn't enough space on this Mac for these items.")
    }
}
