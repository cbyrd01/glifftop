#if os(macOS)
    import GliffInput
    import GliffProtocol
    import Testing

    @testable import GliffSession

    /// Input through a whole session against `fake-server serve input`, which fails on a key or
    /// button pressed twice, released but not held, still held at the end, motion off the
    /// output, or (with its flags) a key before the keymap, input before the activation nudge, or
    /// too few keys or pointer messages.
    extension SessionIntegrationTests {
        static func press(_ code: UInt32) -> InputMessage { .key(code: code, pressed: true) }
        static func release(_ code: UInt32) -> InputMessage { .key(code: code, pressed: false) }

        /// A controller in `mode` with the window key, the app active and a picture: captured.
        static func captured(_ mode: CaptureMode = .integrated) -> InputController {
            var controller = InputController(mode: mode, keymap: "k1")
            for event: CaptureEvent in [.windowKey(true), .appActive(true), .picture(true)] {
                _ = controller.capture(event)
            }
            return controller
        }

        /// Runs `serve input` with `args`; once streaming, sends `inputs` and disconnects at once.
        func input(_ args: [String], _ inputs: [InputMessage]) async throws -> Outcome {
            try await session(
                ["input"] + args,
                onStatus: { status, session in
                    guard case .streaming = status else { return }
                    for input in inputs { session.send(input) }
                    await session.disconnect()
                })
        }

        @Test func keysArriveInOrderAfterTheKeymap() async throws {
            let outcome = try await input(
                ["--keymap-first", "--expect-keys", "2"], [.keymap("k2"), Self.press(30), Self.release(30)])
            #expect(outcome.serverFailure == nil)
            #expect(outcome.end == .disconnected)
        }

        /// A window coming to the front nudges the remote pointer before anything else it sends.
        @Test func activationNudgesFirst() async throws {
            var controller = Self.captured()
            let nudge = controller.activate(at: (x: 100, y: 50)).messages
            let outcome = try await input(
                ["--expect-nudge", "--expect-keys", "2"], nudge + [Self.press(30), Self.release(30)])
            #expect(outcome.serverFailure == nil)
            #expect(outcome.end == .disconnected)
        }

        @Test func keysWithoutTheNudgeFailTheCheck() async throws {
            let outcome = try await input(["--expect-nudge"], [Self.press(30), Self.release(30)])
            #expect(outcome.serverFailure?.contains("nudge") == true)
        }

        /// The app's order: Hello carries no keymap (one the server can't compile would fail
        /// its setup), and the real one is queued before the session runs, so it goes first.
        @Test func aKeymapQueuedBeforeTheSessionRunsGoesFirst() async throws {
            let (session, transport) = try makeSession(["input", "--keymap-first", "--expect-keys", "2"])
            session.send(.keymap("k2"))
            let runner = Task { await session.run() }
            for await status in session.status {
                guard case .streaming = status else { continue }
                session.send(Self.press(30))
                session.send(Self.release(30))
                await session.disconnect()
            }
            await runner.value
            #expect(transport.serverFailure == nil)
        }

        @Test func inputBeforeDisconnectArrivesBeforeBye() async throws {
            let inputs = [Self.press(30), Self.release(30), Self.press(48), Self.release(48)]
            let outcome = try await input(["--expect-keys", "4"], inputs)
            #expect(outcome.serverFailure == nil)
            #expect(outcome.end == .disconnected)
        }

        /// A press queued before the stream is live is dropped: sent, it would stay held.
        @Test func pressesBeforeStreamingAreDropped() async throws {
            let (session, transport) = try makeSession(["input"])
            session.send(Self.press(30))
            let runner = Task { await session.run() }
            for await status in session.status {
                if case .streaming = status { await session.disconnect() }
            }
            await runner.value
            #expect(transport.serverFailure == nil)
        }

        /// Each press released, motion on the output, a scroll's value finite, and all four sent.
        @Test func pointerInputArrivesBalanced() async throws {
            let inputs: [InputMessage] = [
                .pointerMotion(x: 640, y: 360), .pointerButton(code: 0x110, pressed: true),
                .pointerAxis(axis: .vertical, value: 15, discrete: 1, stop: false),
                .pointerButton(code: 0x110, pressed: false),
            ]
            let outcome = try await input(["--expect-pointer", "4"], inputs)
            #expect(outcome.serverFailure == nil)
            #expect(outcome.end == .disconnected)
        }

        /// A release queued just before `disconnect()` still goes before Bye (the app's detach
        /// queues the ledger's releases so).
        @Test func aButtonReleasedJustBeforeDisconnectArrivesBeforeBye() async throws {
            let inputs: [InputMessage] = [
                .pointerButton(code: 0x111, pressed: true), .pointerButton(code: 0x111, pressed: false),
            ]
            let outcome = try await input(["--expect-pointer", "2"], inputs)
            #expect(outcome.serverFailure == nil)
            #expect(outcome.end == .disconnected)
        }
    }
#endif
