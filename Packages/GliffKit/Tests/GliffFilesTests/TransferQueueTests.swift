import Foundation
import GliffSFTP
import GliffTestSupport
import GliffTransport
import Testing

@testable import GliffFiles

/// A host's queue of batches against a scripted host that can hold its WRITE replies back.
@Suite struct TransferQueueTests {
    let source: TemporaryFolder
    let peer = UploadPeer()
    let activity = RecordingActivity()
    let files: HostFiles

    init() throws {
        source = try TemporaryFolder()
        let connection = peer.connection
        files = HostFiles.testing(files: PeerTransport { connection }, activity: activity)
    }

    /// Queues an upload of a new file `name` of `size` bytes.
    func upload(_ name: String, size: Int = 1_000) async throws -> TransferBatch {
        let file = try source.file(name)
        try Data(count: size).write(to: file)
        return await files.enqueue(.upload([file], to: .downloads, clash: .keepBoth), asker: nil)
    }

    func state(_ batch: TransferBatch) -> TransferState { batch.progress.counts.state }

    /// The paths the host was asked to OPEN, in order.
    var opened: [String] {
        peer.connection.requests.filter { $0.type == .open }.map(UploadPeer.path)
    }

    @Test func batchesRunInOrder() async throws {
        defer { source.remove() }
        peer.holdWrites(true)
        let first = try await upload("first.bin")
        let second = try await upload("second.bin")
        #expect(await eventually { peer.held.count == 1 })
        #expect(state(first) == .running && state(second) == .queued)
        peer.holdWrites(false)
        peer.answerHeld()
        #expect(await ends(second))
        #expect(state(first) == .finished && state(second) == .finished)
        #expect(opened.count == 2 && opened[0].contains(".first.bin.") && opened[1].contains(".second.bin."))
    }

    /// The Files window closing during a batch leaves the channel to the batch, which closes it
    /// when it ends.
    @Test func aRunningBatchHoldsTheChannel() async throws {
        defer { source.remove() }
        let window = await files.join(asker: nil)
        _ = try await files.session(for: window)
        peer.holdWrites(true)
        let batch = try await upload("report.pdf")
        #expect(await eventually { peer.held.count == 1 })
        await files.leave(window)
        #expect(!peer.connection.isClosed)
        peer.holdWrites(false)
        peer.answerHeld()
        #expect(await ends(batch))
        #expect(state(batch) == .finished)
        #expect(await eventually { peer.connection.isClosed })
    }

    @Test func theActivityIsHeldWhileWorkRemains() async throws {
        defer { source.remove() }
        peer.holdWrites(true)
        let batch = try await upload("report.pdf")
        #expect(await eventually { peer.held.count == 1 })
        #expect(activity.held)
        #expect(await files.hasWork)
        peer.holdWrites(false)
        peer.answerHeld()
        #expect(await ends(batch))
        #expect(await eventually { !activity.held })
        #expect(await !files.hasWork)
        #expect(activity.begun == 1)
    }

    @Test func streamingCapsTheWindowAtEight() async throws {
        defer { source.remove() }
        files.setStreaming(true)
        peer.holdWrites(true)
        let batch = try await upload("big.bin", size: 4 << 20)
        #expect(await eventually { peer.held.count == 8 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(peer.held.count == 8)
        files.setStreaming(false)
        peer.answerHeld(1)
        #expect(await eventually { peer.held.count == 64 })
        peer.holdWrites(false)
        peer.answerHeld()
        #expect(await ends(batch))
        #expect(state(batch) == .finished)
    }

    @Test func aLostLinkFailsTheBatchWithItsSentence() async throws {
        defer { source.remove() }
        peer.holdWrites(true)
        let batch = try await upload("report.pdf")
        #expect(await eventually { peer.held.count == 1 })
        peer.connection.fail(.exited(status: 255, failure: .sharedConnectionLost))
        #expect(await ends(batch))
        #expect(state(batch) == .failed(.connectionLost))
        #expect(FilesError.connectionLost.message(host: "omarchy") == "The connection to omarchy was lost.")
        #expect(await !files.hasWork)
    }

    /// sftp-server answers in order, but nothing waits for the batch: a listing's request goes
    /// out between its writes.
    @Test func browsingRunsBetweenTransferRequests() async throws {
        defer { source.remove() }
        peer.holdWrites(true)
        let batch = try await upload("big.bin", size: 1 << 20)
        #expect(await eventually { peer.held.count > 1 })
        let window = await files.join(asker: nil)
        let session = try await files.session(for: window)
        await #expect(throws: FilesError.noSuchFile) { try await session.lstat(Array("/home/person/x".utf8)) }
        #expect(state(batch) == .running)
        peer.holdWrites(false)
        peer.answerHeld()
        #expect(await ends(batch))
        await files.leave(window)
    }

    @Test func theRegistryKeepsOneHostFilesPerHost() async throws {
        let registry = FilesRegistry { target in
            HostFiles(
                host: target.value,
                channels: .testing(files: PeerTransport { UploadPeer().connection }, home: "/"),
                ledger: TemporaryLedger(store: MemoryLedgerStore()), activity: RecordingActivity())
        }
        let omarchy = await registry.files(for: try SSHTarget("omarchy"))
        #expect(await registry.files(for: try SSHTarget("omarchy")) === omarchy)
        #expect(await registry.files(for: try SSHTarget("other")) !== omarchy)
        #expect(omarchy.host == "omarchy")
    }

    @Test func cancelStopsTheRunningBatch() async throws {
        defer { source.remove() }
        peer.holdWrites(true)
        let batch = try await upload("report.pdf")
        let next = try await upload("next.pdf")
        #expect(await eventually { peer.held.count == 1 })
        await files.cancel(batch.id)
        peer.holdWrites(false)
        peer.answerHeld()
        #expect(await ends(next))
        #expect(state(batch) == .cancelled && state(next) == .finished)
    }
}
