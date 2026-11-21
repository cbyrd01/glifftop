#if os(macOS)
    import Foundation
    import GliffClipboard
    import GliffInput
    import GliffProtocol
    import Testing

    @testable import GliffSession

    /// Hands over the same bytes for every type.
    struct FixedSource: LocalClipboardSource {
        let bytes: [UInt8]

        func source(for mime: String, token: Int) async throws(TransferError) -> any ChunkSource {
            MemorySource(bytes)
        }
    }

    /// The clipboard through a whole `Session`, against an in-memory server.
    @Suite struct SessionClipboardTests {
        private let text = ClipboardMimes.text
        private let hello = Array("hello".utf8)

        /// A session streaming from `server`, sharing a clipboard of "hello".
        private func streaming(_ server: ScriptedServer) async throws -> (Session, Task<Void, Never>) {
            let session = Session(
                transport: server, configuration: SessionConfiguration(maxWidth: 5120, maxHeight: 2880),
                decoder: SpyDecoder(),
                clipboard: ClipboardSetup(
                    source: FixedSource(bytes: hello)))
            let runner = Task { await session.run() }
            try server.send(fixture: "s00_hello_ack")
            try server.send(fixture: "s01b_stream_config_single")
            for await status in session.status {
                if case .streaming = status { break }
            }
            return (session, runner)
        }

        private func offer() -> LocalClipboardOffer {
            LocalClipboardOffer(mimeTypes: [text], token: 1)
        }

        private func request(_ id: UInt32) -> ClipboardMessage {
            .request(id: id, serial: 1, item: .mime(text))
        }

        private var offered: ClientMessage {
            .clipboard(.offer(serial: 1, mimeTypes: [text], files: []))
        }

        /// Served with no input since the offer.
        @Test func servesWithNoInput() async throws {
            let server = ScriptedServer()
            let (session, runner) = try await streaming(server)
            session.offerClipboard(offer())
            await server.wait(for: offered)
            try server.send(request(2))
            let served = ClientMessage.clipboard(.data(id: 2, offset: 0, dataLength: 5, done: false))
            await server.wait(for: served, payload: hello)
            #expect(server.contains(served, payload: hello))
            await session.disconnect()
            await runner.value
        }

        /// Input sent after the offer goes after it.
        @Test func inputAfterTheOfferWaitsForIt() async throws {
            let server = ScriptedServer()
            let (session, runner) = try await streaming(server)
            session.offerClipboard(offer())
            session.send(.key(code: 30, pressed: true))
            await server.wait(for: .key(keycode: 30, pressed: true))
            let press = try #require(server.index(of: .key(keycode: 30, pressed: true)))
            let offerAt = try #require(server.index(of: offered))
            #expect(offerAt < press)
            session.send(.key(code: 30, pressed: false))
            await session.disconnect()
            await runner.value
        }

        @Test func inputQueuedBeforeTheOfferGoesFirst() async throws {
            let server = ScriptedServer()
            let (session, runner) = try await streaming(server)
            session.send(.key(code: 30, pressed: true))
            session.offerClipboard(offer())
            await server.wait(for: offered)
            let press = try #require(server.index(of: .key(keycode: 30, pressed: true)))
            let offerAt = try #require(server.index(of: offered))
            #expect(press < offerAt)
            session.send(.key(code: 30, pressed: false))
            await session.disconnect()
            await runner.value
        }
    }
#endif
