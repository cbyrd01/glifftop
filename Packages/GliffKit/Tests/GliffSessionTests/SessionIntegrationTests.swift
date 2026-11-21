#if os(macOS)
    import Foundation
    import GliffClipboard
    import GliffProtocol
    @testable import GliffTransport
    import GliffVideo
    import Testing

    @testable import GliffSession

    /// Whole sessions against `fake-server serve <scenario>`. Each checks how the session ended
    /// and that the fake server exited 0 (the client did what the scenario requires).
    @Suite(
        .enabled(if: FakeServer.isAvailable, "set GLIFFTOP_FAKE_SERVER (scripts/test.sh does)"),
        .timeLimit(.minutes(1)))
    struct SessionIntegrationTests {
        struct Outcome {
            var statuses: [SessionStatus]
            var serverFailure: String?
            var end: SessionEnd? {
                if case .ended(let end) = statuses.last { end } else { nil }
            }
        }

        func makeSession(
            _ args: [String], decoder: any FrameDecoder = NullFrameDecoder(),
            features: [any SessionFeature] = [], cursor: CursorSlot = CursorSlot(),
            clipboard: ClipboardSetup? = nil
        ) throws -> (Session, ObservedTransport) {
            let transport = try #require(ObservedTransport(args))
            let session = Session(
                transport: transport, configuration: SessionConfiguration(maxWidth: 4096, maxHeight: 4096),
                decoder: decoder, features: features, cursor: cursor, clipboard: clipboard)
            return (session, transport)
        }

        /// Runs a session to its end. `drive` runs alongside it (to disconnect, say);
        /// `onStatus` sees each status (`status` has one reader: this loop).
        func session(
            _ args: [String], decoder: any FrameDecoder = NullFrameDecoder(),
            features: [any SessionFeature] = [], cursor: CursorSlot = CursorSlot(),
            clipboard: ClipboardSetup? = nil,
            drive: @escaping @Sendable (Session) async -> Void = { _ in },
            onStatus: (SessionStatus, Session) async -> Void = { _, _ in }
        ) async throws -> Outcome {
            let (session, transport) = try makeSession(
                args, decoder: decoder, features: features, cursor: cursor, clipboard: clipboard)
            let runner = Task { await session.run() }
            let driver = Task { await drive(session) }
            var statuses: [SessionStatus] = []
            for await status in session.status {
                statuses.append(status)
                await onStatus(status, session)
            }
            await runner.value
            driver.cancel()
            return Outcome(statuses: statuses, serverFailure: transport.serverFailure)
        }

        /// Streams `args`, disconnecting once frame `last` has been decoded.
        func stream(_ args: [String], last: UInt64, features: [any SessionFeature] = []) async throws -> (
            Outcome, SpyDecoder
        ) {
            let decoder = SpyDecoder()
            let outcome = try await session(args, decoder: decoder, features: features) { session in
                await decoder.waitFor(last)
                await session.disconnect()
            }
            return (outcome, decoder)
        }

        @Test func handshakeThenDisconnect() async throws {
            let outcome = try await session(
                ["handshake"],
                onStatus: { status, session in
                    if case .waitingForVideo = status { await session.disconnect() }
                })
            #expect(outcome.end == .disconnected)
            #expect(outcome.serverFailure == nil)
        }

        @Test(arguments: [("dual", ChromaMode.dual420), ("single", .single420)])
        func streamAcksEveryFrame(chroma: String, mode: ChromaMode) async throws {
            let (outcome, decoder) = try await stream(
                ["stream", "--chroma", chroma, "--frames", "30", "--expect-bye"], last: 30)
            #expect(outcome.end == .disconnected)
            #expect(outcome.serverFailure == nil)
            #expect(decoder.configs.map(\.chroma) == [mode])
            #expect(
                outcome.statuses.contains {
                    if case .streaming(let info) = $0 { info.chroma == mode } else { false }
                })
        }

        @Test func pingFirst() async throws {
            let (outcome, _) = try await stream(["ping-first", "--expect-bye"], last: 3)
            #expect(outcome.end == .disconnected)
            #expect(outcome.serverFailure == nil)
        }

        @Test func configChangeRebuildsOnlyForSize() async throws {
            let (outcome, decoder) = try await stream(["config-change", "--expect-bye"], last: 9)
            #expect(outcome.serverFailure == nil)
            #expect(decoder.configs.map(\.width) == [1280, 1920])
            // The pace-only change reaches the kept decoder as an update.
            #expect(decoder.updates.map(\.fpsCap) == [30])
        }

        @Test func serverErrors() async throws {
            let incompatible = try await session(["error", "1"])
            guard case .incompatible = incompatible.end else {
                Issue.record("\(incompatible.statuses)")
                return
            }
            #expect(incompatible.serverFailure == nil)
            let setup = try await session(["error", "256"])
            #expect(setup.end == .serverSetupFailed("fake error"))
            #expect(setup.serverFailure == nil)
            let version = try await session(["hello-version"])
            guard case .incompatible = version.end else {
                Issue.record("\(version.statuses)")
                return
            }
            #expect(version.serverFailure == nil)
        }

        @Test(arguments: [["drop"], ["drop", "--mid-frame"]])
        func dropIsALostConnection(args: [String]) async throws {
            let outcome = try await session(args)
            #expect(outcome.end == .connectionLost)
            #expect(outcome.serverFailure == nil)
        }

        @Test func garbageIsNotGliff() async throws {
            let outcome = try await session(["garbage"])
            #expect(outcome.end == .remoteNotGliff)
            #expect(outcome.serverFailure == nil)
        }

        @Test func silentServerDisconnects() async throws {
            let clock = ContinuousClock()
            let start = clock.now
            let outcome = try await session(["silent"]) { session in
                try? await Task.sleep(for: .milliseconds(200))
                await session.disconnect()
            }
            #expect(outcome.end == .disconnected)
            #expect(clock.now - start < .seconds(5))
            // nil also means the process is gone: it exited 0.
            #expect(outcome.serverFailure == nil)
        }

        @Test func featureGetsItsVariant() async throws {
            let feature = RecordingFeature()
            let (outcome, _) = try await stream(
                ["feature", "--feature", "test-feature", "--expect-bye"], last: 2, features: [feature])
            #expect(outcome.serverFailure == nil)
            #expect(
                feature.events == [
                    .activated, .received(variant: 99, body: [0x82, 0x18, 99, 0x81, 7], payload: [1, 2, 3]),
                ])
        }

        @Test func otherMessagesAreSkipped() async throws {
            let (outcome, _) = try await stream(["skip", "--frames", "6", "--expect-bye"], last: 6)
            #expect(outcome.end == .disconnected)
            #expect(outcome.serverFailure == nil)
        }

        /// RecorderTests' end-to-end case: the file holds StreamConfig, then frames 1…12.
        @Test func recordingHoldsTheRawStream() async throws {
            let directory = try RecorderTests.directory()
            let decoder = SpyDecoder()
            let (session, transport) = try makeSession(
                ["stream", "--frames", "12", "--expect-bye"], decoder: decoder)
            await session.record(to: directory, for: .seconds(60))
            let runner = Task { await session.run() }
            await decoder.waitFor(12)
            await session.disconnect()
            for await _ in session.status {}
            await runner.value
            #expect(transport.serverFailure == nil)

            let files = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)
            let file = try #require(files.first { $0.pathExtension == "gliffrec" })
            var parser = FrameParser()
            parser.append(try Data(contentsOf: file))
            var messages: [ServerMessage] = []
            while let frame = try parser.next() { messages.append(try ServerMessage.decode(frame.body)) }
            guard case .streamConfig = messages.first else {
                Issue.record("\(messages)")
                return
            }
            let frames = messages.dropFirst().map { message -> UInt64? in
                if case .videoFrame(let header) = message { header.frameID } else { nil }
            }
            #expect(frames == Array(1...12))
            #expect(parser.bufferedByteCount == 0)
        }

        /// A session disconnected before it ran never starts ssh.
        @Test func disconnectBeforeRunNeverConnects() async throws {
            let (session, transport) = try makeSession(["handshake"])
            await session.disconnect()
            await session.run()
            var statuses: [SessionStatus] = []
            for await status in session.status { statuses.append(status) }
            #expect(statuses == [.ended(.disconnected)])
            #expect(transport.connection == nil)
        }

        /// A disconnect while the decoder is being configured: the rest of that StreamConfig's
        /// actions (`.streaming`) are dropped.
        @Test func disconnectDuringConfigureReportsNoStreaming() async throws {
            let decoder = GatedDecoder()
            let outcome = try await session(["stream", "--frames", "1000", "--expect-bye"], decoder: decoder)
            {
                session in
                await decoder.configuring()
                await session.disconnect()
                decoder.open()
            }
            #expect(outcome.end == .disconnected)
            #expect(!outcome.statuses.contains { if case .streaming = $0 { true } else { false } })
            #expect(outcome.serverFailure == nil)
        }

        /// The server goes quiet mid-stream for 8 s (Pongs too): the session reports the
        /// interruption, and its end when the server streams again.
        @Test func aStallInterruptsThenResumes() async throws {
            let (outcome, _) = try await stream(["stall", "8000"], last: 3)
            let marks = outcome.statuses.compactMap { status -> Bool? in
                if case .interrupted(let on) = status { on } else { nil }
            }
            #expect(marks == [true, false])
            #expect(outcome.end == .disconnected)
            #expect(outcome.serverFailure == nil)
        }

        /// A run() cancelled before it starts never starts ssh either.
        @Test func runCancelledBeforeItStartsNeverConnects() async throws {
            let (session, transport) = try makeSession(["handshake"])
            let runner = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                await session.run()
            }
            await runner.value
            var statuses: [SessionStatus] = []
            for await status in session.status { statuses.append(status) }
            #expect(statuses == [.ended(.disconnected)])
            #expect(transport.connection == nil)
        }

        /// Cancelling run() is a disconnect: Bye, then `.disconnected`.
        @Test func cancellingRunDisconnects() async throws {
            let (session, transport) = try makeSession(["stream", "--frames", "1000", "--expect-bye"])
            let runner = Task { await session.run() }
            var last: SessionStatus?
            for await status in session.status {
                if case .stats = status { runner.cancel() }
                last = status
            }
            await runner.value
            #expect(last == .ended(.disconnected))
            #expect(transport.serverFailure == nil)
        }
    }
#endif
