import Foundation
import GliffSFTP
import GliffTestSupport
import Synchronization
import Testing

@testable import GliffFiles

/// Downloads from a scripted host tree, which shows the requests.
@Suite struct DownloadFlowTests {
    let destination: TemporaryFolder
    let store = MemoryLedgerStore()

    init() throws { destination = try TemporaryFolder() }

    /// Plans `paths` on `tree` and downloads them; the peer, to read its requests.
    func download(_ paths: [String], from tree: FakeHostTree) async throws -> (
        ScriptedSFTPPeer, TransferProgress
    ) {
        let peer = tree.peer()
        let session = try await SFTPSession.start(over: peer)
        let plan = try await DownloadPlan.download(
            paths.compactMap { RemotePath(absolute: Array($0.utf8)) }, on: session, to: destination.url)
        let progress = TransferProgress.begun(plan)
        let result = await Result { () async throws(FilesError) in
            try await Download(
                session: session, ledger: TemporaryLedger(store: store), pipeline: Pipeline(),
                progress: progress
            ).run(plan)
        }
        await session.close()
        try result.get()
        return (peer, progress)
    }

    func contents(_ name: String) throws -> [UInt8] {
        Array(try Data(contentsOf: destination.url.appending(path: name)))
    }

    func reads(_ peer: ScriptedSFTPPeer) -> [UInt64] {
        peer.requests.filter { $0.type == .read }.map { request in
            var reader = SFTPReader(request.body)
            _ = try? reader.string()
            return (try? reader.uint64()) ?? .max
        }
    }

    /// This Mac takes README and readme as one name, so the second gets " 2", counted.
    @Test func readmeBesideREADMEBecomesReadme2() async throws {
        defer { destination.remove() }
        var tree = FakeHostTree()
        tree["/src"] = .init(mode: 0o40755)
        tree["/src/README"] = .file(Array("upper".utf8))
        tree["/src/readme"] = .file(Array("lower".utf8))
        let (_, progress) = try await download(["/src"], from: tree)
        #expect(
            (try? LocalFiles.names(in: destination.url.appending(path: "src"))) == ["README", "readme 2"])
        #expect(try contents("src/readme 2") == Array("lower".utf8))
        #expect(progress.counts.renamed == 1)
    }

    @Test func aShortReadIsReaskedAtItsOffset() async throws {
        defer { destination.remove() }
        let bytes = (0..<5_000).map { UInt8($0 % 251) }
        var tree = FakeHostTree()
        tree["/data.bin"] = .file(bytes)
        tree.readCap = 1_000
        let (peer, _) = try await download(["/data.bin"], from: tree)
        #expect(try contents("data.bin") == bytes)
        #expect(reads(peer).sorted() == [0, 1_000, 2_000, 3_000, 4_000, 5_000])
    }

    @Test func aSmallFileCostsOneOrTwoReads() async throws {
        defer { destination.remove() }
        var tree = FakeHostTree()
        tree["/note.txt"] = .file(Array("hello".utf8))
        let (peer, _) = try await download(["/note.txt"], from: tree)
        #expect(try contents("note.txt") == Array("hello".utf8))
        #expect(reads(peer) == [0, 5])
    }

    /// Read in parallel, a file shorter than planned would leave a hole; it fails as changed.
    @Test func aFileShorterThanPlannedFails() async throws {
        defer { destination.remove() }
        var tree = FakeHostTree()
        tree["/data.bin"] = .init(mode: 0o100644, size: 100_000, contents: Array(repeating: 7, count: 40_000))
        await #expect(throws: FilesError.changedWhileCopying) {
            _ = try await download(["/data.bin"], from: tree)
        }
        #expect((try? LocalFiles.names(in: destination.url)) == [])
    }

    @Test func aFileThatGrewALittleArrivesWhole() async throws {
        defer { destination.remove() }
        let bytes = (0..<100_000).map { UInt8($0 % 251) }
        var tree = FakeHostTree()
        tree["/log.txt"] = .init(mode: 0o100644, size: 5, contents: bytes)
        let (_, progress) = try await download(["/log.txt"], from: tree)
        #expect(try contents("log.txt") == bytes)
        #expect(progress.counts.bytesDone == progress.counts.bytesTotal)
    }

    /// Making folders sends no request, so only the fill itself can see a cancel.
    @Test func aCancelledFillMakesNothingMore() async throws {
        let stepped = Mutex(0)
        let filling = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await FolderFill.run(0..<5, atOnce: 8) { (_) async throws(FilesError) -> FolderFill.Copy? in
                stepped.withLock { $0 += 1 }
                return nil
            }
        }
        await #expect(throws: FilesError.cancelled) { try await filling.valueWithin() }
        #expect(stepped.withLock { $0 } == 0)
    }
}
