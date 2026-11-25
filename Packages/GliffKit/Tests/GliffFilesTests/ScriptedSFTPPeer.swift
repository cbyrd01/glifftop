import GliffFiles
import GliffSFTP
import GliffTestSupport
import GliffTransport
import Synchronization
import Testing

/// One request as the peer read it: its type, id (0 for INIT) and the bytes after the id.
struct PeerRequest: Sendable {
    /// Nil for a type the codec doesn't name.
    let type: SFTPPacketType?
    let id: UInt32
    let body: [UInt8]
}

/// A fake sftp server a test scripts: a `ByteConnection` that reads the client's packets and
/// answers as `answer` says (nil: no answer), or as the test sends by hand. It answers INIT
/// with `version` unless that is nil.
final class ScriptedSFTPPeer: ByteConnection {
    let incoming: AsyncThrowingStream<[UInt8], any Error>
    private let continuation: AsyncThrowingStream<[UInt8], any Error>.Continuation
    private let version: [UInt8]?
    private let answer: @Sendable (PeerRequest) -> [UInt8]?
    private let beforeWrite: @Sendable () async -> Void

    private struct State {
        var buffer: [UInt8] = []
        var requests: [PeerRequest] = []
        var closed = false
        var writesFail = false
    }
    private let state = Mutex(State())

    /// `beforeWrite` runs before each write is read, so a test can hold a write back.
    init(
        version: [UInt8]? = SFTPBytes.version,
        answer: @escaping @Sendable (PeerRequest) -> [UInt8]? = { _ in nil },
        beforeWrite: @escaping @Sendable () async -> Void = {}
    ) {
        (incoming, continuation) = AsyncThrowingStream.makeStream()
        (self.version, self.answer, self.beforeWrite) = (version, answer, beforeWrite)
    }

    var requests: [PeerRequest] { state.withLock { $0.requests } }
    var isClosed: Bool { state.withLock { $0.closed } }

    /// Every later write fails, as one to an ssh client that has exited does.
    func failWrites() { state.withLock { $0.writesFail = true } }

    func write(_ bytes: [UInt8]) async throws(TransportError) {
        await beforeWrite()
        if state.withLock({ $0.writesFail }) { throw .writeFailed("Broken pipe") }
        let read = state.withLock { state -> [PeerRequest] in
            state.buffer += bytes
            var read: [PeerRequest] = []
            while state.buffer.count >= 4 {
                let length = state.buffer.prefix(4).reduce(0) { $0 << 8 | Int($1) }
                guard state.buffer.count >= 4 + length else { break }
                let packet = Array(state.buffer[4..<4 + length])
                state.buffer.removeFirst(4 + length)
                // INIT carries a version where other requests carry an id.
                let isInit = packet[0] == 1
                let id = isInit ? 0 : packet[1..<5].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
                read.append(
                    PeerRequest(
                        type: SFTPPacketType(rawValue: packet[0]), id: id,
                        body: Array(packet.dropFirst(isInit ? 1 : 5))))
            }
            state.requests += read
            return read
        }
        for request in read {
            if request.type == .initialize {
                if let version { send(version) }
            } else if let reply = answer(request) {
                send(reply)
            }
        }
    }

    func close() async {
        state.withLock { $0.closed = true }
        continuation.finish()
    }

    /// The session closes its own channel only: abandoning would end the connection under it.
    func abandon() async {
        Issue.record("the session abandoned its connection")
        await close()
    }

    func send(_ bytes: [UInt8]) { continuation.yield(bytes) }
    func end() { continuation.finish() }
    func fail(_ error: TransportError) { continuation.finish(throwing: error) }

    /// Waits for `count` requests after INIT.
    func waitForRequests(_ count: Int) async -> Bool {
        await eventually { requests.filter { $0.type != .initialize }.count >= count }
    }

    /// Starts a READ of 4 bytes on `session` as the first request and cancels it; its id.
    func abandonedRead(on session: SFTPSession) async throws -> UInt32 {
        let read = Task { try await session.read(handle: [1], offset: 0, length: 4) }
        #expect(await waitForRequests(1))
        read.cancel()
        await #expect(throws: FilesError.cancelled) { try await read.value }
        return try #require(requests.last?.id)
    }
}

/// Holds back the next write it is armed for until `release()`: a peer's `beforeWrite`.
final class HeldWrite: Sendable {
    private enum Phase { case idle, armed, held }
    private let phase = Mutex(Phase.idle)
    private let released: AsyncStream<Void>
    private let releaser: AsyncStream<Void>.Continuation

    init() { (released, releaser) = AsyncStream<Void>.makeStream() }

    /// Whether a write is held now.
    var isHeld: Bool { phase.withLock { $0 == .held } }

    /// Holds the next write.
    func arm() { phase.withLock { $0 = .armed } }

    func release() { releaser.yield() }

    @Sendable func beforeWrite() async {
        let hold = phase.withLock { phase in
            guard phase == .armed else { return false }
            phase = .held
            return true
        }
        guard hold else { return }
        for await _ in released { break }
        phase.withLock { $0 = .idle }
    }
}
