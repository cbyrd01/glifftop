#if os(macOS)
    import Foundation
    import GliffInput
    import GliffSession
    import GliffTransport
    import GliffVideo
    import Synchronization
    import Testing

    /// One headless session over the shared connections, with the app's own input rules
    /// (`InputController`) in front of it, as one window's capture.
    final class LiveFocusScreen: Sendable {
        let session: Session
        let pointer: RemotePointerSlot
        /// What this screen's session wrote and read, and when.
        let written = RecordingObserver()
        private let info = Mutex<StreamInfo?>(nil)
        private let input: Mutex<InputController>
        /// The host's reports as the app's capture reads them.
        private let follower: Mutex<HostPointerFollower>
        private let runner = Mutex<Task<Void, Never>?>(nil)
        /// The windows the test opened on this screen, closed at the end wherever they moved.
        let opened = Mutex<Set<String>>([])
        /// The origin of the controller's times.
        private let start = ContinuousClock.now

        /// `largest`: the largest screen the session declares, as the app's window would.
        init(
            connections: HostConnections, target: SSHTarget, mode: CaptureMode = .integrated,
            barrier: InputBarrier? = nil, largest: (width: UInt32, height: UInt32) = (1280, 720)
        ) {
            input = Mutex(InputController(mode: mode, keymap: ""))
            let pointer = RemotePointerSlot()
            self.pointer = pointer
            follower = Mutex(HostPointerFollower(pointer))
            let command = SSHCommand(target: target, serverArguments: ScreenChoice.virtual.serverArguments)
            session = Session(
                transport: ChannelTransport(
                    connections: connections, target: target, command: command.remoteCommand),
                configuration: SessionConfiguration(
                    maxWidth: largest.width, maxHeight: largest.height,
                    keymap: XKBKeymap.text(for: XKBLayout(layout: "us"))),
                decoder: NullFrameDecoder(), pointer: pointer, observer: written, barrier: barrier)
            let session = session
            runner.withLock {
                $0 = Task { [self] in
                    async let run: Void = session.run()
                    for await status in session.status {
                        if case .streaming(let streaming) = status { self.info.withLock { $0 = streaming } }
                    }
                    await run
                }
            }
        }

        private var now: Duration { ContinuousClock.now - start }

        /// The stream, once streaming; throws after 60 s without.
        func streaming() async throws -> StreamInfo {
            for _ in 0..<600 {
                if let streaming = info.withLock({ $0 }) { return streaming }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw CancellationError()
        }

        var geometry: PictureGeometry? { info.withLock { $0 }?.pointerGeometry }

        /// The window's capture changes; what the rules say goes to the host.
        func capture(_ event: CaptureEvent) { send(input.withLock { $0.capture(event) }) }

        /// The window comes to the front: activation on the rising edge, as the app does, onto
        /// the Mac pointer's place over the picture (logical), else where the host's pointer is.
        func activate(macPointer: (x: Double, y: Double)? = nil) throws {
            let geometry = try #require(geometry)
            let target = try #require(
                Self.target(macPointer: macPointer, host: pointer.latest, geometry: geometry))
            // As the app: the nudge (`Session.activate`) before what capture turning on sends.
            let captured = input.withLock { controller in
                [CaptureEvent.appActive(true), .picture(true), .windowKey(true)].map {
                    controller.capture($0)
                }
            }
            session.activate(input.withLock { $0.activate(at: target) }.messages)
            captured.forEach(send)
        }

        func key(_ code: UInt16, _ kind: MacKeyEvent.Kind, flags: MacModifierFlags = []) {
            send(input.withLock { $0.key(MacKeyEvent(keyCode: code, kind: kind, flags: flags.rawValue)) })
        }

        /// Super with `code`, pressed and released, through the rules.
        func chord(_ code: UInt16) {
            let held = LiveScreens.superHeld
            key(LiveScreens.superKey, .flagsChanged, flags: held)
            key(code, .down(isRepeat: false), flags: held)
            key(code, .up, flags: held)
            key(LiveScreens.superKey, .flagsChanged)
        }

        /// Capture mode: the pointer enters the picture, and confinement starts where the host's
        /// pointer is, as after an activation.
        func confine() throws {
            let geometry = try #require(geometry)
            // As the app's start: one look at the host's pointer, and only reports after it are
            // followed.
            let host = follower.withLock { $0.start() }
            let at = try #require(Self.target(host: host.latest, geometry: geometry))
            capture(.pointerOnPicture(true))
            input.withLock {
                $0.confine(
                    x: at.x, y: at.y, hostHiddenAt: host.hiddenAt, newPicture: host.newPicture,
                    geometry: geometry, at: now)
            }
            try #require(confinedPointer != nil, "confinement never started")
        }

        var confinedPointer: (x: Double, y: Double, visible: Bool)? { input.withLock { $0.confinedPointer } }

        /// A Mac pointer delta, confined; what it sent.
        @discardableResult func delta(dx: Double, dy: Double) -> [InputMessage] {
            let result = input.withLock { $0.pointerMoved(dx: dx, dy: dy, at: now) }
            send(result)
            return result.messages
        }

        /// One wheel step, down or up, at (640, 360), with `flags` (no key event for them).
        func scroll(down: Bool, flags: MacModifierFlags = []) {
            let step = ScrollEvent(
                deltaX: 0, deltaY: down ? -1 : 1, isPrecise: false, phase: .none, isMomentum: false)
            send(input.withLock { $0.pointer(.scroll(step, x: 640, y: 360, flags: flags.rawValue)) })
        }

        /// The host's reports since the last call, through the rules as the app's tick gives
        /// them; whether the virtual pointer followed one (a warp).
        func followHost() throws -> Bool {
            let geometry = try #require(geometry)
            let reports = reports()
            return input.withLock { $0.followHost(reports, drawn: geometry, at: now) }
        }

        /// The host's reports since the last call (this one's or `followHost`'s), as they came.
        func reports() -> [(bufferX: Double, bufferY: Double, visible: Bool)?] {
            follower.withLock { $0.reports() }
        }

        /// Where an activation puts the remote pointer: the Mac pointer's place over the picture,
        /// else the host's pointer, else the centre.
        private static func target(
            macPointer: (x: Double, y: Double)? = nil, host: RemotePointerSlot.Position?,
            geometry: PictureGeometry
        ) -> (x: Double, y: Double)? {
            FocusTarget.target(macPointer: macPointer, cursor: host.map { ($0.x, $0.y) }, geometry: geometry)
        }

        private func send(_ result: InputResult) {
            for message in result.messages { session.send(message) }
        }

        func end() async {
            await session.disconnect()
            await runner.withLock { $0 }?.value
        }
    }
#endif
