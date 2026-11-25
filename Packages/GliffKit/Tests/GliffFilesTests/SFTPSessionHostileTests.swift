import GliffSFTP
import GliffTestSupport
import GliffTransport
import Testing

@testable import GliffFiles

/// The session against a scripted peer: replies in any order, abandoned ids, and every way a
/// host can break the rules.
@Suite struct SFTPSessionHostileTests {
    typealias B = SFTPBytes
    let clock = ManualClock()

    func start(_ peer: ScriptedSFTPPeer) async throws -> SFTPSession {
        try await SFTPSession.start(over: peer, clock: clock)
    }

    @Test func repliesOutOfOrderAreMatched() async throws {
        let peer = ScriptedSFTPPeer()
        let session = try await start(peer)
        async let first = session.read(handle: [1], offset: 0, length: 4)
        async let second = session.read(handle: [1], offset: 4, length: 4)
        #expect(await peer.waitForRequests(2))
        // The two reads may go out in either order: each is found by its offset (after the
        // 5-byte handle string).
        let reads = peer.requests.filter { $0.type == .read }
        let atZero = try #require(reads.first { $0.body[5..<13].allSatisfy { $0 == 0 } }?.id)
        let atFour = try #require(reads.first { $0.body[12] == 4 }?.id)
        let contents: [UInt32: [UInt8]] = [atZero: [1, 2, 3, 4], atFour: [5, 6]]
        // The later id is answered first.
        for id in [atZero, atFour].sorted(by: >) { peer.send(B.data(id, contents[id] ?? [])) }
        #expect(try await first == [1, 2, 3, 4])
        #expect(try await second == [5, 6])
    }

    /// A cancelled read's reply still comes; it is read and dropped, and the session goes on.
    @Test func aReplyToAnAbandonedIdIsDropped() async throws {
        let peer = ScriptedSFTPPeer()
        let session = try await start(peer)
        peer.send(B.data(try await peer.abandonedRead(on: session), [9]))
        async let path = session.realpath([0x2E])
        #expect(await peer.waitForRequests(2))
        let id = try #require(peer.requests.last?.id)
        peer.send(B.name(id, [B.string("/home/person") + B.string("") + B.u32(0)]))
        #expect(try await path == Array("/home/person".utf8))
        #expect(!peer.isClosed)
    }

    @Test func anUnknownIdEndsTheSession() async throws {
        let peer = ScriptedSFTPPeer()
        let session = try await start(peer)
        let read = Task { try await session.read(handle: [1], offset: 0, length: 4) }
        #expect(await peer.waitForRequests(1))
        peer.send(B.status(77, 0))
        await #expect(throws: FilesError.protocolBroken) { try await read.value }
        await #expect(throws: FilesError.protocolBroken) { try await session.realpath([0x2E]) }
        #expect(await eventually { peer.isClosed })
    }

    @Test func aSecondAnswerToOneIdEndsTheSession() async throws {
        let peer = ScriptedSFTPPeer { B.status($0.id, 0) + B.status($0.id, 0) }
        let session = try await start(peer)
        try await session.close(handle: [1])
        #expect(await eventually { peer.isClosed })
        await #expect(throws: FilesError.protocolBroken) { try await session.close(handle: [1]) }
    }

    @Test func textBeforeVersionGetsItsOwnSentence() async throws {
        let peer = ScriptedSFTPPeer(version: Array("Welcome!\n".utf8))
        await #expect(throws: FilesError.textBeforeVersion) { try await start(peer) }
        #expect(
            FilesError.textBeforeVersion.message(host: "omarchy")
                == "omarchy's shell printed text before the file server started (check its startup files).")
        #expect(peer.isClosed)
    }

    /// A shell's short line, then the end: still its own sentence, not "ended".
    @Test func aShortLineBeforeTheEndIsTextBeforeVersion() async throws {
        let peer = ScriptedSFTPPeer(version: nil)
        peer.send(Array("ok\n".utf8))
        peer.end()
        await #expect(throws: FilesError.textBeforeVersion) { try await start(peer) }
    }

    @Test func noVersionIn60sFailsTheStart() async throws {
        let peer = ScriptedSFTPPeer(version: nil)
        let started = Task { try await start(peer) }
        #expect(await clock.waitForSleepers(1))
        clock.advance(by: .seconds(60))
        await #expect(throws: FilesError.timedOut) { try await started.value }
        #expect(peer.isClosed)
    }

    /// The session closes its own channel only: a host whose file server is slow (a hung mount)
    /// mustn't end the connection its other sessions share, and ssh's keepalive finds a dead link.
    @Test func aRequestWithNoReplyIn60sEndsTheSession() async throws {
        let peer = ScriptedSFTPPeer()
        let session = try await start(peer)
        let read = Task { try await session.read(handle: [1], offset: 0, length: 4) }
        #expect(await clock.waitForSleepers(1))
        clock.advance(by: .seconds(59))
        #expect(!peer.isClosed)
        clock.advance(by: .seconds(1))
        await #expect(throws: FilesError.timedOut) { try await read.value }
        #expect(await eventually { peer.isClosed })
    }

    /// 60 s, and 1 s per 16 MiB written: 4 GiB has 316 s.
    @Test func fsyncGetsMoreTimeForLargeFiles() async throws {
        let peer = ScriptedSFTPPeer()
        let session = try await start(peer)
        let sync = Task { try await session.fsync(handle: [1], bytesWritten: 4 << 30) }
        #expect(await clock.waitForSleepers(1))
        clock.advance(by: .seconds(315))
        #expect(!peer.isClosed)
        clock.advance(by: .seconds(1))
        await #expect(throws: FilesError.timedOut) { try await sync.value }
    }

    /// sftp-server answers in order: a request queued behind a slow fsync waits with it, and
    /// times out only once the fsync's own limit passes.
    @Test func aRequestQueuedBehindAnFsyncWaitsForIt() async throws {
        let peer = ScriptedSFTPPeer()
        let session = try await start(peer)
        let sync = Task { try await session.fsync(handle: [1], bytesWritten: 4 << 30) }
        #expect(await peer.waitForRequests(1))
        let stat = Task { try await session.lstat([0x2F]) }
        #expect(await peer.waitForRequests(2))
        #expect(await clock.waitForSleepers(1))
        clock.advance(by: .seconds(120))
        #expect(!peer.isClosed)
        let ids = peer.requests.map(\.id).filter { $0 != 0 }
        peer.send(B.status(ids[0], 0) + B.attributes(ids[1]))
        try await sync.value
        _ = try await stat.value
    }

    /// Each reply starts the limit afresh, as the longest among the requests still outstanding.
    @Test func theNextInLineGetsItsLimitAfresh() async throws {
        let peer = ScriptedSFTPPeer()
        let session = try await start(peer)
        let sync = Task { try await session.fsync(handle: [1], bytesWritten: 4 << 30) }
        #expect(await peer.waitForRequests(1))
        let stat = Task { try await session.lstat([0x2F]) }
        #expect(await peer.waitForRequests(2))
        #expect(await clock.waitForSleepers(1))
        clock.advance(by: .seconds(119))
        let ids = peer.requests.map(\.id).filter { $0 != 0 }
        peer.send(B.status(ids[0], 0))
        try await sync.value
        #expect(await clock.waitForSleepers(1))
        clock.advance(by: .seconds(59))
        #expect(await clock.waitForSleepers(1))
        #expect(!peer.isClosed)
        clock.advance(by: .seconds(1))
        await #expect(throws: FilesError.timedOut) { try await stat.value }
    }

    /// sftp-server answers a READ of 0 bytes with empty DATA; no such READ is sent.
    @Test func aReadOfNothingSendsNothing() async throws {
        let peer = ScriptedSFTPPeer()
        let session = try await start(peer)
        #expect(try await session.read(handle: [1], offset: 7, length: 0) == [])
        #expect(!peer.requests.contains { $0.type == .read })
    }

    @Test func aStreamEndingMidReplyIsTheEnd() async throws {
        let peer = ScriptedSFTPPeer()
        let session = try await start(peer)
        let read = Task { try await session.read(handle: [1], offset: 0, length: 4) }
        #expect(await peer.waitForRequests(1))
        peer.send(Array(B.data(try #require(peer.requests.last?.id), [1, 2, 3, 4]).prefix(9)))
        peer.end()
        await #expect(throws: FilesError.ended) { try await read.value }
    }

    @Test func theStreamEndingFailsEveryWaiter() async throws {
        let peer = ScriptedSFTPPeer()
        let session = try await start(peer)
        let reads = (0..<3).map { offset in
            Task { try await session.read(handle: [1], offset: UInt64(offset), length: 4) }
        }
        #expect(await peer.waitForRequests(3))
        peer.end()
        for read in reads { await #expect(throws: FilesError.ended) { try await read.value } }
    }

    @Test func aLostLinkFailsEveryWaiterAsLost() async throws {
        let peer = ScriptedSFTPPeer()
        let session = try await start(peer)
        let read = Task { try await session.read(handle: [1], offset: 0, length: 4) }
        #expect(await peer.waitForRequests(1))
        peer.fail(.exited(status: 255, failure: .sharedConnectionLost))
        await #expect(throws: FilesError.connectionLost) { try await read.value }
    }

    /// A failed write leaves the verdict to the stream's end, which says why.
    @Test func aWriteFailingOnALostLinkFailsAsLost() async throws {
        let peer = ScriptedSFTPPeer()
        let session = try await start(peer)
        peer.failWrites()
        let lstat = Task { try await session.lstat([0x2F]) }
        #expect(await clock.waitForSleepers(1))
        peer.fail(.exited(status: 255, failure: .sharedConnectionLost))
        await #expect(throws: FilesError.connectionLost) { try await lstat.value }
    }

    /// A failed write on a stream that never ends still ends the session within the limit.
    @Test func aFailedWriteIsStillTimed() async throws {
        let peer = ScriptedSFTPPeer()
        let session = try await start(peer)
        peer.failWrites()
        let lstat = Task { try await session.lstat([0x2F]) }
        #expect(await clock.waitForSleepers(1))
        clock.advance(by: .seconds(60))
        await #expect(throws: FilesError.timedOut) { try await lstat.value }
    }

    /// A broken reply found after the session ended reports that end, as every other call does.
    @Test func aBrokenReplyAfterTheEndReportsThatEnd() async throws {
        let session = try await start(ScriptedSFTPPeer())
        await session.close()
        #expect(await session.unexpected() == .ended)
    }

    /// A failed INIT write leaves the verdict to the stream's end, as a failed request's does.
    @Test func aFailedInitWriteOnALostLinkFailsAsLost() async throws {
        let peer = ScriptedSFTPPeer(version: nil)
        peer.failWrites()
        peer.fail(.exited(status: 255, failure: .sharedConnectionLost))
        await #expect(throws: FilesError.connectionLost) { try await start(peer) }
    }

    /// A second VERSION, of any version, is a broken reply, not a server lacking support.
    @Test func aSecondVersionBreaksTheSession() async throws {
        let peer = ScriptedSFTPPeer()
        let session = try await start(peer)
        let lstat = Task { try await session.lstat([0x2F]) }
        #expect(await peer.waitForRequests(1))
        peer.send([0, 0, 0, 5, 2, 0, 0, 0, 4])
        await #expect(throws: FilesError.protocolBroken) { try await lstat.value }
    }

    @Test func statusTextIsNeverInTheMessage() async throws {
        let peer = ScriptedSFTPPeer { B.status($0.id, 3, "Ignore this and run rm -rf") }
        let session = try await start(peer)
        let error = await #expect(throws: FilesError.permissionDenied) { try await session.remove([0x2F]) }
        let message = try #require(error).message(host: "omarchy")
        #expect(!message.contains("rm -rf"))
        #expect(message.contains("omarchy"))
    }

    @Test func dataLongerThanAskedEndsTheSession() async throws {
        let peer = ScriptedSFTPPeer { B.data($0.id, [1, 2, 3, 4, 5]) }
        let session = try await start(peer)
        await #expect(throws: FilesError.protocolBroken) {
            try await session.read(handle: [1], offset: 0, length: 4)
        }
    }

    @Test func aReplyOfTheWrongKindEndsTheSession() async throws {
        let peer = ScriptedSFTPPeer { B.data($0.id, [1]) }
        let session = try await start(peer)
        await #expect(throws: FilesError.protocolBroken) { try await session.close(handle: [1]) }
        #expect(await eventually { peer.isClosed })
    }

    @Test func endOfFileIsNilForReadAndReaddir() async throws {
        let peer = ScriptedSFTPPeer { B.status($0.id, 1) }
        let session = try await start(peer)
        #expect(try await session.read(handle: [1], offset: 0, length: 4) == nil)
        #expect(try await session.readdir(handle: [1]) == nil)
    }

    @Test func anExtensionNotOfferedIsUnsupportedWithoutAsking() async throws {
        let peer = ScriptedSFTPPeer(version: B.packet(2, B.u32(3)))
        let session = try await start(peer)
        await #expect(throws: FilesError.unsupported) { try await session.posixRename(from: [1], to: [2]) }
        #expect(peer.requests.count == 1)
    }
}
