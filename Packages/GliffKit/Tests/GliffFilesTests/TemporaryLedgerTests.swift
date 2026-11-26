import Foundation
import Synchronization
import Testing

@testable import GliffFiles

/// A store that keeps its entries in memory, or refuses to save.
final class MemoryLedgerStore: LedgerStore {
    let entries = Mutex<[LedgerEntry]>([])
    let refuses: Bool

    init(refuses: Bool = false) { self.refuses = refuses }

    func load() -> [LedgerEntry] { entries.withLock { $0 } }

    func save(_ entries: [LedgerEntry]) throws {
        if refuses {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSUnderlyingErrorKey: POSIXError(.ENOSPC)])
        }
        self.entries.withLock { $0 = entries }
    }
}

@Suite struct TemporaryLedgerTests {
    static let upload = LedgerEntry.remote(
        host: "omarchy",
        path: RemotePath(absolute: Array("/home/person/Downloads/.a.glifftop-0000abcd".utf8))!,
        isFolder: true)

    @Test func theLedgerSurvivesARestart() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let store = FileLedgerStore(url: folder.url.appending(path: "ledger.json"))
        let local = LedgerEntry.local(path: "/Users/person/Downloads/.b.glifftop-0000beef")
        let first = TemporaryLedger(store: store)
        try await first.record(local)
        try await first.record(Self.upload)

        let second = TemporaryLedger(store: store)
        #expect(await second.localLeftovers() == ["/Users/person/Downloads/.b.glifftop-0000beef"])
        #expect(await second.remoteLeftovers(for: "omarchy") == [Self.upload])
        #expect(await second.remoteLeftovers(for: "other").isEmpty)
    }

    @Test func aForgottenEntryIsGone() async throws {
        let store = MemoryLedgerStore()
        let ledger = TemporaryLedger(store: store)
        try await ledger.record(Self.upload)
        await ledger.forget(Self.upload)
        #expect(store.load().isEmpty)
        #expect(await TemporaryLedger(store: store).remoteLeftovers(for: "omarchy").isEmpty)
    }

    /// A name the ledger can't keep isn't made.
    @Test func aRecordThatCantBeSavedIsRefused() async {
        let ledger = TemporaryLedger(store: MemoryLedgerStore(refuses: true))
        await #expect(throws: FilesError.local(.noSpace)) { try await ledger.record(Self.upload) }
        #expect(await ledger.remoteLeftovers(for: "omarchy").isEmpty)
    }

    /// A temporary a batch records while the app runs is that batch's, never a leftover.
    @Test func aLiveBatchsTemporaryIsNotALeftover() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let file = try folder.file(".report.pdf.glifftop-0000abcd", "partial")
        let ledger = TemporaryLedger(store: MemoryLedgerStore())
        try await ledger.record(.local(path: file.path(percentEncoded: false)))
        try await ledger.record(Self.upload)
        await ledger.removeLocalLeftovers()
        #expect(FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
        #expect(await ledger.localLeftovers().isEmpty)
        #expect(await ledger.remoteLeftovers(for: "omarchy").isEmpty)
    }

    /// A temporary on a volume that isn't mounted is kept for a later launch.
    @Test func aTemporaryOnAMissingVolumeIsKept() async throws {
        let store = MemoryLedgerStore()
        let path = "/Volumes/GliffFiles-\(UUID())/Downloads/.a.glifftop-0000abcd"
        try await TemporaryLedger(store: store).record(.local(path: path))
        let ledger = TemporaryLedger(store: store)
        await ledger.removeLocalLeftovers()
        #expect(await ledger.localLeftovers() == [path])
        #expect(store.load() == [.local(path: path)])
    }

    /// One entry that can't be read (an older shape, a path no longer accepted) loses only itself.
    @Test func anUnreadableEntryIsSkipped() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let good = try String(decoding: JSONEncoder().encode(LedgerEntry.local(path: "/a")), as: UTF8.self)
        let bad = #"{"remote":{"host":"omarchy","path":[46,46],"isFolder":true}}"#
        let file = try folder.file("ledger.json", "[\(bad),\(good),{\"later\":{}}]")
        #expect(FileLedgerStore(url: file).load() == [.local(path: "/a")])
    }

    @Test func aMissingOrBrokenFileIsEmpty() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        #expect(FileLedgerStore(url: folder.url.appending(path: "none.json")).load().isEmpty)
        let broken = try folder.file("broken.json", "{not json")
        #expect(FileLedgerStore(url: broken).load().isEmpty)
    }

    /// Only the recorded names go, a folder with what the batch put in it; a look-alike stays.
    @Test func localTemporariesAreRemovedAtLaunch() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let file = try folder.file(".report.pdf.glifftop-0000abcd", "partial")
        let tree = folder.url.appending(path: ".photos.glifftop-0000beef")
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: false)
        try Data("x".utf8).write(to: tree.appending(path: "a.jpg"))
        let lookAlike = try folder.file(".notes.glifftop-0000cafe", "keep")
        let store = MemoryLedgerStore()
        let before = TemporaryLedger(store: store)
        for url in [file, tree] { try await before.record(.local(path: url.path(percentEncoded: false))) }

        let ledger = TemporaryLedger(store: store)
        await ledger.removeLocalLeftovers()
        #expect(!FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: tree.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: lookAlike.path(percentEncoded: false)))
        #expect(await ledger.localLeftovers().isEmpty)
        #expect(store.load().isEmpty)
    }
}
