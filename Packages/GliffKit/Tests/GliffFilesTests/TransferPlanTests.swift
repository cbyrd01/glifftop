import Foundation
import GliffSFTP
import GliffTestSupport
import Testing

@testable import GliffFiles

/// Plans of Mac items (real files in a temporary folder) and of host items (a fake host tree).
@Suite struct TransferPlanTests {
    static let downloads = RemotePath(absolute: Array("/home/person/Downloads".utf8))!

    static func names<Source, Destination>(_ plan: TransferPlan<Source, Destination>) -> [String] {
        plan.items.map { $0.path.map { String(decoding: $0.raw, as: UTF8.self) }.joined(separator: "/") }
    }

    func upload(_ urls: [URL]) throws(FilesError) -> UploadPlan {
        try UploadPlan.upload(urls, to: Self.downloads)
    }

    func download(_ paths: [String], from tree: FakeHostTree) async throws -> DownloadPlan {
        let session = try await SFTPSession.start(over: tree.peer())
        defer { Task { await session.close() } }
        return try await DownloadPlan.download(
            paths.map { RemotePath(absolute: Array($0.utf8))! }, on: session,
            to: URL(filePath: "/Users/person/Downloads"))
    }

    @Test func aFolderIsPlannedFolderFirst() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let photos = folder.url.appending(path: "photos")
        try FileManager.default.createDirectory(
            at: photos.appending(path: "2026"), withIntermediateDirectories: true)
        try Data("abc".utf8).write(to: photos.appending(path: "a.jpg"))
        try Data("hello".utf8).write(to: photos.appending(path: "2026/b.jpg"))
        chmod(photos.appending(path: "a.jpg").path(percentEncoded: false), 0o640)
        let plan = try upload([photos])
        #expect(Self.names(plan) == ["photos", "photos/2026", "photos/2026/b.jpg", "photos/a.jpg"])
        #expect(plan.items.map(\.isFolder) == [true, true, false, false])
        #expect(plan.items.last?.mode == 0o640)
        #expect(plan.items.last?.source == photos.appending(path: "a.jpg"))
        #expect(plan.totalBytes == 8)
        #expect(plan.destination == Self.downloads)
        #expect(plan.items.allSatisfy { $0.modified != nil })
    }

    /// A later try's plan leaves out the top-level items done, with all they hold.
    @Test func droppingTopLevelItemsDropsWhatTheyHold() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        try folder.file("photos/2026/b.jpg", "hello")
        try folder.file("a.txt", "abc")
        try folder.file("c.txt", "c")
        let plan = try upload(["photos", "a.txt", "c.txt"].map { folder.url.appending(path: $0) })
        #expect(Self.names(plan.droppingTopLevel(0)) == Self.names(plan))
        #expect(plan.droppingTopLevel(0).totalBytes == 9)
        let rest = plan.droppingTopLevel(1)
        #expect(Self.names(rest) == ["a.txt", "c.txt"])
        #expect(rest.totalBytes == 4)
        #expect(plan.droppingTopLevel(3).items.isEmpty)
        #expect(plan.droppingTopLevel(5).totalBytes == 0)
    }

    /// A link that leads nowhere is skipped and counted; the rest of the batch goes on.
    @Test func aDanglingTopLevelLinkIsSkipped() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let file = try folder.file("report.pdf", "abc")
        let dangling = folder.url.appending(path: "old")
        try FileManager.default.createSymbolicLink(
            at: dangling, withDestinationURL: folder.url.appending(path: "gone"))
        let local = try upload([file, dangling])
        #expect(local.items.count == 1 && local.linksSkipped == 1)

        var tree = FakeHostTree()
        tree["/home/person/report.pdf"] = .init(mode: 0o100644, size: 3)
        tree["/home/person/old"] = .init(mode: 0o120777, target: "/home/person/gone")
        let remote = try await download(["/home/person/report.pdf", "/home/person/old"], from: tree)
        #expect(remote.items.count == 1 && remote.linksSkipped == 1)
    }

    /// `lstat` of a path ending in `/` follows a link; the plan never asks with one.
    @Test func aTrailingSlashDoesntHideALink() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let target = folder.url.appending(path: "target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let link = folder.url.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let plan = try upload([
            URL(filePath: link.path(percentEncoded: false) + "/", directoryHint: .isDirectory)
        ])
        #expect(Self.names(plan) == ["link"])
        #expect(plan.items.first?.source.lastPathComponent == "target")
    }

    @Test func aCancelledPlanStops() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        _ = try folder.file("a.txt")
        let result = try await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return Result { () throws(FilesError) in try upload([folder.url]) }
        }.valueWithin()
        #expect(throws: FilesError.cancelled) { try result.get() }
    }

    @Test func aFIFOIsSkippedAndCounted() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let file = try folder.file("a.txt", "abc")
        #expect(mkfifo(folder.url.appending(path: "pipe").path(percentEncoded: false), 0o600) == 0)
        let plan = try upload([folder.url])
        #expect(plan.items.count == 2)
        #expect(plan.items.last?.source == file)
        #expect(plan.specialsSkipped == 1)
        // A FIFO dropped by itself is skipped the same way, never opened.
        #expect(try upload([folder.url.appending(path: "pipe")]).specialsSkipped == 1)
    }

    @Test func aSocketIsSkippedAndCounted() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let (_, descriptor) = try folder.socket("s")
        defer { close(descriptor) }
        let plan = try upload([folder.url])
        #expect(plan.items.count == 1)
        #expect(plan.specialsSkipped == 1)
    }

    @Test func linksInsideAFolderAreSkipped() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let file = try folder.file("a.txt", "abc")
        try FileManager.default.createSymbolicLink(
            at: folder.url.appending(path: "to-file"), withDestinationURL: file)
        try FileManager.default.createSymbolicLink(
            at: folder.url.appending(path: "loop"), withDestinationURL: folder.url)
        let plan = try upload([folder.url])
        #expect(plan.items.count == 2)
        #expect(plan.linksSkipped == 2)
        #expect(plan.totalBytes == 3)
    }

    @Test func aTopLevelLinkToAFileIsFollowed() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let file = try folder.file("report.pdf", "12345")
        let link = folder.url.appending(path: "latest.pdf")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        let plan = try upload([link])
        #expect(Self.names(plan) == ["latest.pdf"])
        #expect(plan.items.first?.source.resolvingSymlinksInPath() == file.resolvingSymlinksInPath())
        #expect(plan.items.first.map { TemporaryFolder.status($0.source).st_mode & S_IFMT } == S_IFREG)
        #expect(plan.totalBytes == 5)
    }

    @Test func aTopLevelLinkToADeviceIsRefused() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let link = folder.url.appending(path: "null")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(filePath: "/dev/null"))
        let local = try upload([link])
        #expect(local.items.isEmpty && local.specialsSkipped == 1)

        var tree = FakeHostTree()
        tree["/home/person/tty"] = .init(mode: 0o120777, target: "/dev/tty1")
        tree["/dev/tty1"] = .init(mode: 0o20620)
        let remote = try await download(["/home/person/tty"], from: tree)
        #expect(remote.items.isEmpty && remote.specialsSkipped == 1)
    }

    @Test func aHostTreeIsPlanned() async throws {
        var tree = FakeHostTree()
        tree["/home/person/photos"] = .init(mode: 0o40755)
        tree["/home/person/photos/a.jpg"] = .init(mode: 0o100640, size: 10)
        tree["/home/person/photos/sub"] = .init(mode: 0o40700)
        tree["/home/person/photos/sub/b.jpg"] = .init(mode: 0o100644, size: 20)
        tree["/home/person/photos/link"] = .init(mode: 0o120777, target: "/home/person/photos/a.jpg")
        tree["/home/person/photos/fifo"] = .init(mode: 0o10644)
        tree["/home/person/photos/unmarked"] = .init(mode: nil, size: 5)
        tree["/home/person/latest"] = .init(mode: 0o120777, target: "/data/report.pdf")
        tree["/data/report.pdf"] = .init(mode: 0o100600, size: 7)
        let plan = try await download(["/home/person/photos", "/home/person/latest"], from: tree)
        #expect(Self.names(plan) == ["photos", "photos/a.jpg", "photos/sub", "photos/sub/b.jpg", "latest"])
        #expect(plan.items.map(\.mode) == [0o755, 0o640, 0o700, 0o644, 0o600])
        #expect(plan.items.first?.source.raw == Array("/home/person/photos".utf8))
        #expect(plan.items[3].source.raw == Array("/home/person/photos/sub/b.jpg".utf8))
        // A top-level link is read from where it leads, as REALPATH found it.
        #expect(plan.items[4].source.raw == Array("/data/report.pdf".utf8))
        // The tree sends no times: none is made up.
        #expect(plan.items.allSatisfy { $0.modified == nil })
        #expect(plan.totalBytes == 37)
        #expect(plan.linksSkipped == 1)
        #expect(plan.specialsSkipped == 2)
    }

    /// A name whose shown form can't be a Mac name is skipped and counted.
    @Test func aNameWithNoMacFormIsSkipped() async throws {
        var tree = FakeHostTree()
        tree["/a"] = .init(mode: 0o40755)
        tree["/a/ok"] = .init(mode: 0o100644)
        tree["/a/" + String(repeating: "\u{1}", count: 200)] = .init(mode: 0o100644)
        let plan = try await download(["/a"], from: tree)
        #expect(Self.names(plan) == ["a", "a/ok"])
        #expect(plan.unusableNames == 1)
    }

    /// Names a listing skips are entries seen too, across the batch, not just in their folder.
    @Test func skippedNamesCountTowardTheLimit() async throws {
        var tree = FakeHostTree()
        tree["/a"] = .init(mode: 0o40755)
        for index in 0..<60_000 { tree["/a/x\u{0}\(index)"] = .init(mode: 0o100644) }
        tree["/b"] = .init(mode: 0o40755)
        for index in 0..<40_000 { tree["/b/\(index)"] = .init(mode: 0o100644) }
        await #expect(throws: FilesError.tooLarge) { try await download(["/a", "/b"], from: tree) }
    }

    @Test func hostileSizesSaturate() async throws {
        var tree = FakeHostTree()
        tree["/big"] = .init(mode: 0o40755)
        tree["/big/a"] = .init(mode: 0o100644, size: .max - 1)
        tree["/big/b"] = .init(mode: 0o100644, size: .max - 1)
        let plan = try await download(["/big"], from: tree)
        #expect(plan.totalBytes == .max)
        #expect(plan.items.count == 3)
    }

    @Test(arguments: [64, 65])
    func tooDeepFails(depth: Int) throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let deepest = (1..<depth).reduce(folder.url.appending(path: "d")) { url, _ in url.appending(path: "d")
        }
        try FileManager.default.createDirectory(at: deepest, withIntermediateDirectories: true)
        if depth > 64 {
            #expect(throws: FilesError.tooLarge) { try upload([folder.url.appending(path: "d")]) }
        } else {
            #expect(try upload([folder.url.appending(path: "d")]).items.count == depth)
        }
    }

    @Test func tooManyEntriesFails() async throws {
        var tree = FakeHostTree()
        for (folder, count) in [("/a", 60_000), ("/b", 39_998)] {
            tree[folder] = .init(mode: 0o40755)
            for index in 0..<count { tree["\(folder)/\(index)"] = .init(mode: 0o100644) }
        }
        #expect(try await download(["/a", "/b"], from: tree).items.count == 100_000)
        tree["/b/one-more"] = .init(mode: 0o100644)
        await #expect(throws: FilesError.tooLarge) { try await download(["/a", "/b"], from: tree) }
    }

    @Test func tooLargeHasASentence() {
        #expect(
            FilesError.tooLarge.message(host: "omarchy")
                == "There are too many items to copy at once (at most 100,000, 64 folders deep).")
    }
}
