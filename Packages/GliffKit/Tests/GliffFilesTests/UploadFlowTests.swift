import Foundation
import GliffSFTP
import GliffTestSupport
import Synchronization
import Testing

@testable import GliffFiles

/// Uploads to a scripted host, which shows the requests and holds replies back.
@Suite struct UploadFlowTests {
    static let downloads = RemotePath(absolute: Array("/home/person/Downloads".utf8)) ?? .root
    let source: TemporaryFolder
    let store = MemoryLedgerStore()

    init() throws { source = try TemporaryFolder() }

    /// Starts uploading `names` from the source folder to the peer's Downloads.
    func start(
        _ peer: UploadPeer, _ names: [String], pipeline: Pipeline = Pipeline()
    ) async throws -> (Task<Void, any Error>, SFTPSession) {
        let plan = try UploadPlan.upload(names.map { source.url.appending(path: $0) }, to: Self.downloads)
        let session = try await SFTPSession.start(over: peer.connection)
        let upload = Upload(
            session: session, host: "omarchy", ledger: TemporaryLedger(store: store), pipeline: pipeline,
            progress: TransferProgress(plan), clash: .keepBoth)
        return (Task { try await upload.run(plan) }, session)
    }

    func bigFile(_ name: String, mebibytes: Int) throws {
        try Data(count: mebibytes << 20).write(to: try source.file(name))
    }

    @Test func theTemporaryHasTheFinalModeFromTheStart() async throws {
        defer { source.remove() }
        chmod(try source.file("secret.txt", "x").path(percentEncoded: false), 0o600)
        let peer = UploadPeer()
        let (task, session) = try await start(peer, ["secret.txt"])
        try await task.value
        await session.close()
        let open = try #require(peer.connection.requests.first { $0.type == .open })
        #expect(try UploadPeer.openAttributes(open).permissions == 0o600)
        #expect(UploadPeer.path(open).hasPrefix("/home/person/Downloads/.secret.txt.glifftop-"))
        // WRITE | CREAT | EXCL
        #expect(
            open.body.dropFirst(4 + UploadPeer.path(open).utf8.count).prefix(4).elementsEqual([0, 0, 0, 0x2A])
        )
        #expect(
            peer.connection.requests.last { $0.type == .rename }.map(UploadPeer.path) == UploadPeer.path(open)
        )
    }

    @Test func cancelWithSixtyFourWritesInFlightThenList() async throws {
        defer { source.remove() }
        try bigFile("big.bin", mebibytes: 4)
        let peer = UploadPeer()
        peer.holdWrites(true)
        let (task, session) = try await start(peer, ["big.bin"])
        #expect(await eventually { peer.held.count == 64 })
        task.cancel()
        await #expect(throws: FilesError.cancelled) { try await task.value }
        #expect(peer.writes.count == 64)
        let types = peer.connection.requests.compactMap(\.type)
        #expect(types.suffix(2) == [.close, .remove])
        #expect(store.load().isEmpty)
        peer.answerHeld()
        let listing = try await RemoteListing.read(Self.downloads, on: session)
        #expect(listing.entries.isEmpty)
        await session.close()
    }

    /// A file inside a folder that fails stops the files copying beside it.
    @Test func aFailingFileStopsItsSiblings() async throws {
        defer { source.remove() }
        try bigFile("mix/a.bin", mebibytes: 4)
        try source.file("mix/b.txt", "b")
        let peer = UploadPeer(refusing: "/b.txt")
        peer.holdWrites(true)
        let (task, session) = try await start(peer, ["mix"])
        // The held writes are never answered: the batch must end without them.
        let ended = Mutex(false)
        Task {
            _ = await task.result
            ended.withLock { $0 = true }
        }
        #expect(await eventually { ended.withLock { $0 } })
        await #expect(throws: FilesError.permissionDenied) { try await task.value }
        #expect(peer.writes.count <= 64)
        await session.close()
    }

    /// A temporary's name found taken at OPEN isn't the batch's: nothing is removed.
    @Test func aTemporaryNotMadeIsNotRemoved() async throws {
        defer { source.remove() }
        try source.file("report.pdf", "x")
        let peer = UploadPeer(refusing: ".glifftop-", code: 4)
        let (task, session) = try await start(peer, ["report.pdf"])
        await #expect(throws: FilesError.failure) { try await task.value }
        await session.close()
        #expect(!peer.connection.requests.contains { $0.type == .remove })
        #expect(store.load().isEmpty)
    }

    /// A file that turned special after planning is skipped, counted, and counts as done.
    @Test func aFileTurnedSpecialIsSkippedAndDone() async throws {
        defer { source.remove() }
        let file = try source.file("pipe", "x")
        let plan = try UploadPlan.upload([file], to: Self.downloads)
        try FileManager.default.removeItem(at: file)
        #expect(mkfifo(file.path(percentEncoded: false), 0o644) == 0)
        let peer = UploadPeer()
        let session = try await SFTPSession.start(over: peer.connection)
        let progress = TransferProgress(plan)
        try await Upload(
            session: session, host: "omarchy", ledger: TemporaryLedger(store: store), pipeline: Pipeline(),
            progress: progress, clash: .keepBoth
        ).run(plan)
        await session.close()
        #expect(progress.counts.specialsSkipped == 1)
        #expect(progress.counts.itemsDone == progress.counts.itemsTotal)
        #expect(!peer.connection.requests.contains { $0.type == .open })
    }

    @Test func notEnoughSpaceFailsBeforeAnyByte() async throws {
        defer { source.remove() }
        try source.file("a.bin", String(repeating: "x", count: 10_000))
        let peer = UploadPeer(space: 4_096)
        let (task, session) = try await start(peer, ["a.bin"])
        await #expect(throws: FilesError.noSpace) { try await task.value }
        await session.close()
        #expect(!peer.connection.requests.contains { $0.type == .open || $0.type == .mkdir })
    }

    @Test func smallFilesRunSeveralAtOnce() async throws {
        defer { source.remove() }
        for index in 0..<20 { try source.file("many/\(index).txt", "x") }
        let peer = UploadPeer()
        peer.holdWrites(true)
        let (task, session) = try await start(peer, ["many"])
        #expect(await eventually { peer.held.count == 8 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(peer.openNow == 8 && peer.held.count == 8)
        peer.holdWrites(false)
        peer.answerHeld()
        try await task.value
        await session.close()
        #expect(peer.mostOpen == 8)
        #expect(peer.writes.count == 20)
    }

    @Test func theWindowShrinksMidFile() async throws {
        defer { source.remove() }
        try bigFile("big.bin", mebibytes: 4)
        let peer = UploadPeer()
        let pipeline = Pipeline()
        peer.holdWrites(true)
        let (task, session) = try await start(peer, ["big.bin"], pipeline: pipeline)
        #expect(await eventually { peer.held.count == 64 })
        pipeline.setWindow(8)
        // 4 of the 64 stay out, so 4 new may go.
        peer.answerHeld(60)
        #expect(await eventually { peer.held.count == 8 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(peer.held.count == 8)
        peer.holdWrites(false)
        peer.answerHeld()
        try await task.value
        await session.close()
        #expect(peer.writes.count == 128)
    }
}
