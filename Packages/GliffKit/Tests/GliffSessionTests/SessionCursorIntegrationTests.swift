#if os(macOS)
    import GliffInput
    import Testing

    @testable import GliffSession

    /// Cursor shapes through a whole session against `fake-server serve cursor`, which sends a
    /// valid shape (id 7, its frame carrying four bytes more than it declares), one with its
    /// hotspot outside (id 8) and one with its pixels a byte short (id 9), then two frames;
    /// with `--valid-only`, only the first.
    extension SessionIntegrationTests {
        /// Runs `serve cursor` until both frames are decoded (the shapes came first), then
        /// disconnects; returns the slot. A session that ends first fails here, not by timing out.
        private func cursorSession(_ args: [String] = []) async throws -> CursorSlot {
            let cursor = CursorSlot()
            let decoder = SpyDecoder()
            let outcome = try await session(
                ["cursor", "--expect-bye"] + args, decoder: decoder, cursor: cursor
            ) {
                session in
                await decoder.waitFor(2)
                await session.disconnect()
            }
            #expect(outcome.end == .disconnected)
            #expect(outcome.serverFailure == nil)
            return cursor
        }

        @Test func aShapeReachesTheSlot() async throws {
            let latest = try #require(try await cursorSession(["--valid-only"]).latest)
            #expect(latest.generation == 1)
            let image = try #require(latest.image)
            let pixels: [UInt8] = [0, 0, 255, 255, 255, 255, 255, 255, 0, 0, 255, 255, 255, 255, 255, 255]
            #expect(image.id == 7 && image.width == 2 && image.height == 2)
            #expect(image.hotX == 1 && image.hotY == 1)
            #expect(image.bgra == pixels)
            #expect(image.isVisible)
        }

        /// The remote's shape changed to one that can't be shown: the arrow, not the old shape
        /// (upstream's `set_remote_cursor`).
        @Test func anInvalidShapeLeavesNoShape() async throws {
            let latest = try #require(try await cursorSession().latest)
            #expect(latest.image == nil)
            #expect(latest.generation == 3)
        }
    }

    /// The remote pointer's position through a whole session, against an in-memory server.
    @Suite struct RemotePointerTests {
        /// The last CursorPos (upstream's fixture: 100.5, 200.75, visible) is held until a
        /// StreamConfig brings a new picture; one that changes only the pace keeps it, as the
        /// server sends a position only when the pointer moves.
        @Test func theSlotHoldsTheLatest() async throws {
            let server = ScriptedServer()
            let pointer = RemotePointerSlot()
            let session = Session(
                transport: server, configuration: SessionConfiguration(maxWidth: 5120, maxHeight: 2880),
                decoder: SpyDecoder(), pointer: pointer)
            let runner = Task { await session.run() }
            try server.send(fixture: "s00_hello_ack")
            try server.send(fixture: "s01b_stream_config_single")
            try server.send(fixture: "s04_cursor_pos")
            let held = RemotePointerSlot.Position(x: 100.5, y: 200.75, visible: true)
            #expect(await Self.eventually { pointer.latest == held })
            try server.send(fixture: "s01b_stream_config_single")
            try await Task.sleep(for: .milliseconds(100))
            #expect(pointer.latest == held)
            try server.send(fixture: "s01_stream_config_dual")
            #expect(await Self.eventually { pointer.latest == nil })
            await session.disconnect()
            await runner.value
        }

        /// An ended session's pointer is nowhere.
        @Test func anEndedSessionClearsTheSlot() async throws {
            let server = ScriptedServer()
            let pointer = RemotePointerSlot()
            let session = Session(
                transport: server, configuration: SessionConfiguration(maxWidth: 5120, maxHeight: 2880),
                decoder: SpyDecoder(), pointer: pointer)
            let runner = Task { await session.run() }
            try server.send(fixture: "s00_hello_ack")
            try server.send(fixture: "s01b_stream_config_single")
            try server.send(fixture: "s04_cursor_pos")
            #expect(await Self.eventually { pointer.latest != nil })
            await session.disconnect()
            await runner.value
            #expect(pointer.latest == nil)
        }

        /// Polls `condition` for up to 2 s.
        private static func eventually(_ condition: () -> Bool) async -> Bool {
            for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
            return condition()
        }
    }
#endif
