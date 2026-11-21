#if os(macOS)
    import Foundation
    import GliffProtocol
    import GliffTransport
    import Synchronization

    @testable import GliffProtocol

    /// An in-memory server: the test feeds it frames and reads what the client wrote.
    final class ScriptedServer: Transport, ByteConnection {
        let incoming: AsyncThrowingStream<[UInt8], any Error>
        private let feed: AsyncThrowingStream<[UInt8], any Error>.Continuation
        private let written = Mutex<(parser: FrameParser, frames: [Frame])>((FrameParser(), []))

        init() {
            (incoming, feed) = AsyncThrowingStream.makeStream()
        }

        func connect() async throws(TransportError) -> any ByteConnection { self }

        func write(_ bytes: [UInt8]) async throws(TransportError) {
            written.withLock { state in
                state.parser.append(bytes)
                while let frame = try? state.parser.next() { state.frames.append(frame) }
            }
        }

        func close() async { feed.finish() }

        /// What the client wrote, in order.
        var frames: [Frame] { written.withLock { $0.frames } }

        /// Where `message` (with `payload`) is among what the client wrote.
        func index(of message: ClientMessage, payload: [UInt8] = []) -> Int? {
            frames.firstIndex(of: Frame(body: message.encoded, payload: payload))
        }

        func contains(_ message: ClientMessage, payload: [UInt8] = []) -> Bool {
            index(of: message, payload: payload) != nil
        }

        /// Waits up to 2 s for `message` to be written.
        func wait(for message: ClientMessage, payload: [UInt8] = []) async {
            for _ in 0..<200 where !contains(message, payload: payload) {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }

        /// Sends one of upstream's golden server messages (GliffProtocolTests' fixtures).
        func send(fixture name: String) throws {
            let url = URL(filePath: #filePath).deletingLastPathComponent()
                .appending(path: "../GliffProtocolTests/Fixtures/\(name).cbor")
            feed.yield(try Frame.encode(body: Array(try Data(contentsOf: url))))
        }

        /// Sends a clipboard message as the server would.
        func send(_ message: ClipboardMessage, payload: [UInt8] = []) throws {
            var writer = CBORWriter()
            message.encode(to: &writer, variant: message.kind.serverVariant)
            feed.yield(try Frame.encode(body: writer.bytes, payload: payload))
        }
    }
#endif
