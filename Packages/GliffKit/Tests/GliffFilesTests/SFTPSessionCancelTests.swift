import GliffSFTP
import GliffTestSupport
import Testing

@testable import GliffFiles

/// Cancelled requests: what they leave open on the host, and how long they may wait.
@Suite struct SFTPSessionCancelTests {
    typealias B = SFTPBytes
    typealias Peer = ScriptedSFTPPeer
    let clock = ManualClock()

    /// An OPEN cancelled before its HANDLE comes: the handle is closed when it does.
    @Test func aCancelledOpenClosesItsHandle() async throws {
        let peer = Peer()
        let session = try await SFTPSession.start(over: peer, clock: clock)
        let open = Task { try await session.open([0x2F, 0x78], flags: .read) }
        #expect(await peer.waitForRequests(1))
        open.cancel()
        await #expect(throws: FilesError.cancelled) { try await open.value }
        let id = try #require(peer.requests.last?.id)
        peer.send(B.handle(id, [7, 7]))
        #expect(
            await eventually { peer.requests.contains { $0.type == .close && $0.body == B.string([7, 7]) } })
        #expect(!peer.isClosed)
    }

    /// Cleanup from a cancelled task: CLOSE still goes out, and its answer comes back.
    @Test func aCancelledTaskStillClosesAHandle() async throws {
        let peer = Peer(answer: { B.status($0.id, 0) })
        let session = try await SFTPSession.start(over: peer, clock: clock)
        let close = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await session.close(handle: [3])
        }
        try await close.value
        #expect(peer.requests.contains { $0.type == .close })
    }

    /// A start cancelled before it begins sends nothing and says so.
    @Test func aCancelledStartIsCancelled() async throws {
        let peer = Peer()
        let started = Task { [clock] in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await SFTPSession.start(over: peer, clock: clock)
        }
        await #expect(throws: FilesError.cancelled) { try await started.value }
        #expect(peer.requests.isEmpty)
    }

    /// A start cancelled while VERSION is awaited is a cancel, not a host failure.
    @Test func aStartCancelledWhileWaitingIsCancelled() async throws {
        let peer = Peer(version: nil)
        let started = Task { [clock] in try await SFTPSession.start(over: peer, clock: clock) }
        #expect(await eventually { peer.requests.count == 1 })
        started.cancel()
        await #expect(throws: FilesError.cancelled) { try await started.value }
    }

    /// A cancelled request whose reply never comes still ends the session after 60 s.
    @Test func aCancelledRequestStillTimesOut() async throws {
        let peer = Peer()
        let session = try await SFTPSession.start(over: peer, clock: clock)
        let read = Task { try await session.read(handle: [1], offset: 0, length: 4) }
        #expect(await clock.waitForSleepers(1))
        read.cancel()
        await #expect(throws: FilesError.cancelled) { try await read.value }
        clock.advance(by: .seconds(60))
        #expect(await eventually { peer.isClosed })
    }

    /// The limit counts from when the request is written, not from when it waits to be.
    @Test func timeSpentWritingIsNotCounted() async throws {
        let gate = HeldWrite()
        let peer = Peer(answer: { B.status($0.id, 0) }, beforeWrite: gate.beforeWrite)
        let session = try await SFTPSession.start(over: peer, clock: clock)
        gate.arm()
        let removed = Task { try await session.remove(Array("/tmp/x".utf8)) }
        #expect(await eventually { gate.isHeld })
        #expect(clock.sleeperCount == 0)
        clock.advance(by: .seconds(61))
        gate.release()
        try await removed.value
        #expect(!peer.isClosed)
    }

    /// A request written while an older one is still being written is timed: a server that
    /// stops reading can't hold the session forever.
    @Test func aRequestWrittenBehindOneStillWritingIsTimed() async throws {
        let gate = HeldWrite()
        let peer = Peer(beforeWrite: gate.beforeWrite)
        let session = try await SFTPSession.start(over: peer, clock: clock)
        gate.arm()
        let first = Task { try await session.remove(Array("/a".utf8)) }
        #expect(await eventually { gate.isHeld })
        let second = Task { try await session.lstat(Array("/b".utf8)) }
        #expect(await peer.waitForRequests(1))
        #expect(await clock.waitForSleepers(1))
        clock.advance(by: .seconds(61))
        defer { gate.release() }
        try #require(await eventually { peer.isClosed })
        await #expect(throws: FilesError.timedOut) { try await second.value }
        gate.release()
        await #expect(throws: FilesError.timedOut) { try await first.value }
        #expect(clock.sleeperCount == 0)
    }

    /// A write that finishes while the timer runs doesn't restart it: only a reply does.
    @Test func aWriteFinishingLaterDoesNotRestartTheTimer() async throws {
        let gate = HeldWrite()
        let peer = Peer(beforeWrite: gate.beforeWrite)
        let session = try await SFTPSession.start(over: peer, clock: clock)
        gate.arm()
        let first = Task { try await session.remove(Array("/a".utf8)) }
        #expect(await eventually { gate.isHeld })
        let second = Task { try await session.lstat(Array("/b".utf8)) }
        #expect(await clock.waitForSleepers(1))
        clock.advance(by: .seconds(40))
        gate.release()
        #expect(await peer.waitForRequests(2))
        clock.advance(by: .seconds(21))
        defer { clock.advance(by: .seconds(60)) }
        try #require(await eventually { peer.isClosed })
        await #expect(throws: FilesError.timedOut) { try await second.value }
        await #expect(throws: FilesError.timedOut) { try await first.value }
    }

    /// Any reply of the wrong kind breaks the session, its request abandoned or not; a HANDLE
    /// in it is not closed.
    @Test(arguments: [true, false])
    func aWrongReplyToAnAbandonedReadEndsTheSession(handle: Bool) async throws {
        let peer = Peer()
        let session = try await SFTPSession.start(over: peer, clock: clock)
        let id = try await peer.abandonedRead(on: session)
        peer.send(handle ? B.handle(id, [9]) : B.attributes(id))
        try #require(await eventually { peer.isClosed })
        #expect(!peer.requests.contains { $0.type == .close })
        await #expect(throws: FilesError.protocolBroken) { try await session.lstat([0x2F]) }
    }
}
