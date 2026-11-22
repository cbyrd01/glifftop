import GliffProtocol
import Synchronization

@testable import GliffClipboard

/// What an engine sent, in order: each message and its payload's length.
final class Wire: Sendable {
    private let sent = Mutex<[(message: ClipboardMessage, payload: Int)]>([])

    func record(_ message: ClipboardMessage, _ payload: [UInt8]) {
        sent.withLock { $0.append((message, payload.count)) }
    }

    var messages: [ClipboardMessage] { sent.withLock { $0.map(\.message) } }

    var dataCount: Int {
        messages.count { if case .data = $0 { true } else { false } }
    }

    func contains(_ message: ClipboardMessage) -> Bool { messages.contains(message) }

    /// Waits (up to 2 s) until `condition` holds.
    func wait(until condition: @Sendable (Wire) -> Bool) async {
        for _ in 0..<200 where !condition(self) {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// A client engine whose messages go to a `Wire`, nothing answering.
func recordedClient(idleTimeout: Duration = ClipboardLimits.idleTimeout) -> (ClipboardTransfers, Wire) {
    let wire = Wire()
    let engine = ClipboardTransfers(side: .client, idleTimeout: idleTimeout) { wire.record($0, $1) }
    return (engine, wire)
}

/// A client and a server engine back to back. The server serves each request from `items`
/// (by item), or refuses it.
final class BackToBack: Sendable {
    let client: ClipboardTransfers
    let server: ClipboardTransfers

    init(items: [(ClipboardItem, [UInt8])]) {
        let peers = Mutex<(client: ClipboardTransfers?, server: ClipboardTransfers?)>((nil, nil))
        client = ClipboardTransfers(side: .client) { message, payload in
            guard let server = peers.withLock({ $0.server }) else { return }
            if case .request(let id, _, let item)? = await server.receive(message, payload: payload) {
                if let bytes = items.first(where: { $0.0 == item })?.1 {
                    await server.serve(id: id, from: MemorySource(bytes), progress: nil)
                } else {
                    await server.refuse(id: id)
                }
            }
        }
        server = ClipboardTransfers(side: .server) { message, payload in
            guard let client = peers.withLock({ $0.client }) else { return }
            _ = await client.receive(message, payload: payload)
        }
        peers.withLock { $0 = (client, server) }
    }
}

/// A sink or source that stalls, ignoring cancellation, until released.
final class Stall: Sendable {
    private let released = Mutex(false)
    private let calls = Mutex(0)

    var callCount: Int { calls.withLock { $0 } }

    func release() { released.withLock { $0 = true } }

    /// Stalls every wait again, one already waiting included, until the next release.
    func rearm() { released.withLock { $0 = false } }

    func wait() async {
        calls.withLock { $0 += 1 }
        while !released.withLock({ $0 }) {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// A sink whose writes stall until released.
final class StallingSink: ChunkSink {
    let stall = Stall()
    func write(_ bytes: [UInt8]) async throws { await stall.wait() }
    func finish() async throws {}
}

/// A source whose reads stall until released.
final class StallingSource: ChunkSource {
    let stall = Stall()
    func read(upTo count: Int) async throws -> [UInt8] {
        await stall.wait()
        return []
    }
}

/// A source that hands over everything in one read, whatever it is asked for.
final class GreedySource: ChunkSource {
    private let bytes: Mutex<[UInt8]>
    init(_ bytes: [UInt8]) { self.bytes = Mutex(bytes) }
    func read(upTo count: Int) async throws -> [UInt8] {
        bytes.withLock { bytes in
            defer { bytes = [] }
            return bytes
        }
    }
}

/// How each serve ended, by id (nil: it finished).
final class Ends: Sendable {
    private let ends = Mutex<[UInt32: TransferError?]>([:])

    func callback(_ id: UInt32) -> @Sendable (TransferError?) -> Void {
        { reason in self.ends.withLock { $0[id] = reason } }
    }

    var all: [UInt32: TransferError?] { ends.withLock { $0 } }

    func wait(for count: Int) async {
        for _ in 0..<200 where all.count < count {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// The test pattern: byte i is i % 251.
func pattern(_ count: Int) -> [UInt8] { (0..<count).map { UInt8($0 % 251) } }

/// A source whose every read fails.
struct FailingSource: ChunkSource {
    struct Failure: Error {}
    func read(upTo count: Int) async throws -> [UInt8] { throw Failure() }
}
