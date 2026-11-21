import GliffTransport
import Synchronization
import Testing

@testable import GliffSession

/// A connection whose first write waits until `release()`, recording every write as it starts.
final class HeldConnection: ByteConnection {
    let incoming = AsyncThrowingStream<[UInt8], any Error> { $0.finish() }
    private let written = Mutex<[[UInt8]]>([])
    private let gate: AsyncStream<Void>
    private let opener: AsyncStream<Void>.Continuation

    init() { (gate, opener) = AsyncStream.makeStream() }

    var writes: [[UInt8]] { written.withLock { $0 } }

    func write(_ bytes: [UInt8]) async throws(TransportError) {
        let first = written.withLock { written in
            written.append(bytes)
            return written.count == 1
        }
        if first { for await _ in gate {} }
    }

    func close() async {}

    func release() { opener.finish() }

    /// Waits up to 2 s for `count` writes to have started.
    func waitFor(_ count: Int) async {
        for _ in 0..<200 where writes.count < count { try? await Task.sleep(for: .milliseconds(10)) }
    }
}

@Suite struct SessionWriterTests {
    @Test func urgentFramesOvertakeQueuedBulk() async {
        let connection = HeldConnection()
        let writer = SessionWriter(connection: connection) { _ in }
        writer.sendBulk([1])
        await connection.waitFor(1)
        writer.sendBulk([2])
        writer.sendBulk([3])
        writer.send([9])
        connection.release()
        await connection.waitFor(4)
        #expect(connection.writes == [[1], [9], [2], [3]])
    }

    @Test func finishingDropsBulk() async {
        let queue = FrameQueue()
        queue.push([2], bulk: true)
        queue.push([9], bulk: false)
        queue.finish()
        #expect(await queue.next() == [9])
        #expect(await queue.next() == nil)
    }

    /// Input that never stops can't hold clipboard data back past its timeout.
    @Test func bulkIsNeverStarved() async {
        let queue = FrameQueue()
        queue.push([0], bulk: true)
        for byte in UInt8(1)...10 { queue.push([byte], bulk: false) }
        var order: [UInt8] = []
        for _ in 0..<11 { order += await queue.next() ?? [] }
        #expect(order == [1, 2, 3, 4, 5, 6, 7, 8, 0, 9, 10])
    }
}
