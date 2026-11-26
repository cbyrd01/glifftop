#if os(macOS)
    import GliffInput
    import GliffProtocol
    import GliffTestSupport
    import Testing

    @testable import GliffSession

    /// The input modes through a whole session against `fake-server serve input`: what
    /// `InputController` sends over the chrome, confined, around a menu and behind the barrier
    /// leaves nothing held, stays on the output, nudges first and keeps its order.
    extension SessionIntegrationTests {
        /// Mac key codes: ⌘ (left), T and A.
        private static let commandKey: UInt16 = 0x37
        private static let keyT: UInt16 = 0x11
        private static let keyA: UInt16 = 0x00
        private static let command: MacModifierFlags = [.command, .leftCommand]

        /// An `InputController`, and what it has said to send.
        private struct Driver {
            var controller: InputController
            var messages: [InputMessage] = []

            mutating func key(
                _ code: UInt16, _ kind: MacKeyEvent.Kind = .flagsChanged, _ flags: MacModifierFlags = [],
                overChrome: Bool = false
            ) {
                let event = MacKeyEvent(keyCode: code, kind: kind, flags: flags.rawValue)
                messages += controller.key(event, overChrome: { overChrome }).messages
            }

            mutating func click(_ pressed: Bool, _ flags: MacModifierFlags = []) {
                pointer(.button(number: 0, pressed: pressed, x: 10, y: 20, flags: flags.rawValue))
            }

            mutating func pointer(_ event: PointerEvent) { messages += controller.pointer(event).messages }

            mutating func capture(_ event: CaptureEvent) -> InputResult {
                let result = controller.capture(event)
                messages += result.messages
                return result
            }
        }

        /// `input(_:_:)`, expecting the server satisfied and the session disconnected.
        private func expectClean(_ args: [String], _ messages: [InputMessage]) async throws {
            let outcome = try await input(args, messages)
            #expect(outcome.serverFailure == nil)
            #expect(outcome.end == .disconnected)
        }

        /// ⌘ held on the picture, then ⌘T over the chrome: the host lets go of Super first. ⌘
        /// pressed over the chrome, then a ⌘-click on the picture: Super joins the click.
        @Test func theChromeHandOffLeavesNothingHeld() async throws {
            var driver = Driver(controller: Self.captured())
            driver.key(Self.commandKey, .flagsChanged, Self.command)
            driver.key(Self.keyT, .down(isRepeat: false), Self.command, overChrome: true)
            driver.key(Self.keyT, .up, Self.command)
            driver.key(Self.commandKey)
            driver.key(Self.commandKey, .flagsChanged, Self.command, overChrome: true)
            driver.click(true, Self.command)
            driver.click(false, Self.command)
            driver.key(Self.commandKey)
            try await expectClean(["--expect-keys", "2", "--expect-pointer", "2"], driver.messages)
        }

        /// Capture's deltas far past each edge, a click and a scroll with its stop: every
        /// position stays on the 1280×720 output.
        @Test func confinedDeltasStayInsideTheOutput() async throws {
            var driver = Driver(controller: Self.captured(.confined))
            _ = driver.capture(.pointerOnPicture(true))
            let geometry = PictureGeometry(
                streamWidth: 1280, streamHeight: 720, viewWidth: 1280, viewHeight: 720, scaleMilli: 1000)
            driver.controller.confine(x: 640, y: 360, geometry: geometry, at: .zero)
            let deltas: [(dx: Double, dy: Double)] = [(2000, 0), (0, 2000), (-4000, 0), (0, -4000)]
            for (dx, dy) in deltas {
                driver.messages += driver.controller.pointerMoved(dx: dx, dy: dy, at: .zero).messages
            }
            driver.click(true)
            driver.click(false)
            let scroll = ScrollEvent(
                deltaX: 0, deltaY: 2, isPrecise: true, phase: .changed, isMomentum: false)
            let end = ScrollEvent(deltaX: 0, deltaY: 0, isPrecise: true, phase: .ended, isMomentum: false)
            driver.pointer(.scroll(scroll, x: 10, y: 20, flags: 0))
            driver.pointer(.scroll(end, x: 10, y: 20, flags: 0))
            try await expectClean(["--expect-pointer", "6"], driver.messages)
        }

        /// A menu opened and closed before the first key brings no second nudge: the
        /// activation's nudge still comes first.
        @Test func aMenuBeforeTheFirstKeyAddsNoNudge() async throws {
            var driver = Driver(controller: Self.captured())
            driver.messages = driver.controller.activate(at: (x: 100, y: 50)).messages
            _ = driver.capture(.menuOpen(true))
            #expect(!driver.capture(.menuOpen(false)).activates)
            driver.key(Self.keyA, .down(isRepeat: false))
            driver.key(Self.keyA, .up)
            try await expectClean(["--expect-nudge", "--expect-keys", "2"], driver.messages)
        }

        /// Another session has just let go of Super: this session's keymap and keys wait 30 ms
        /// (the queue's one sleeper on the barrier's clock), together and in order, then go.
        @Test func heldInputStillArrivesInOrder() async throws {
            let clock = ManualClock()
            let barrier = InputBarrier(clock: clock)
            _ = barrier.wait(before: Self.release(125), from: InputBarrier.Sender())
            let (session, transport) = try makeSession(
                ["input", "--keymap-first", "--expect-keys", "2"], barrier: barrier)
            session.send(.keymap("k2"))
            let runner = Task { await session.run() }
            for await status in session.status {
                guard case .streaming = status else { continue }
                session.send(Self.press(30))
                session.send(Self.release(30))
                #expect(await clock.waitForSleepers(1))
                // The appends' wakeups find the queue held and pass.
                try? await Task.sleep(for: .milliseconds(100))
                clock.advance(by: InputBarrier.gap)
                // The hold's end wakes the drain: the queue empties before the disconnect.
                #expect(await Self.emptied(session.inputs))
                await session.disconnect()
            }
            await runner.value
            #expect(transport.serverFailure == nil)
        }

        /// Waits until `queue` is empty; false if it isn't within 5 s.
        private static func emptied(_ queue: InputQueue) async -> Bool {
            for _ in 0..<500 where !queue.isEmpty {
                try? await Task.sleep(for: .milliseconds(10))
            }
            return queue.isEmpty
        }

        /// A press queued before the stream, held by the barrier past the handshake, is still
        /// judged at the handshake and dropped: sent once streaming, it would stay held.
        @Test func aHeldPressBeforeStreamingIsDropped() async throws {
            let clock = ManualClock()
            let barrier = InputBarrier(clock: clock)
            _ = barrier.wait(before: Self.release(125), from: InputBarrier.Sender())
            let (session, transport) = try makeSession(["input"], barrier: barrier)
            session.send(Self.press(30))
            let runner = Task { await session.run() }
            for await status in session.status {
                guard case .streaming = status else { continue }
                clock.advance(by: InputBarrier.gap)
                await session.disconnect()
            }
            await runner.value
            #expect(transport.serverFailure == nil)
        }
    }
#endif
