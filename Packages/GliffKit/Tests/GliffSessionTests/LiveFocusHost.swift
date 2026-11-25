#if os(macOS)
    import Foundation
    import GliffClipboard
    import GliffInput
    import GliffSession
    import GliffTransport
    import GliffVideo
    import Synchronization
    import Testing

    /// The host side of `LiveFocusTests`: `hyprctl` over the Mac's own ssh (`BatchMode`), read
    /// as JSON. Only numbers and ids are kept.
    enum LiveHyprland {
        static func run(_ script: String) throws -> String {
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/ssh")
            process.arguments = [
                "-o", "BatchMode=yes", LiveHost.target ?? "",
                "export HYPRLAND_INSTANCE_SIGNATURE=$(ls -t ${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/hypr | head -1); "
                    + script,
            ]
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }

        static func json(_ command: String) throws -> Any {
            try JSONSerialization.jsonObject(with: Data(try run("hyprctl -j " + command).utf8))
        }

        struct Monitor {
            let id: Int
            let name: String
            let x, y: Double
            let workspace: Int
        }

        static func monitors() throws -> [Monitor] {
            let list = try #require(try json("monitors") as? [[String: Any]])
            return list.compactMap { entry in
                guard let id = entry["id"] as? Int, let name = entry["name"] as? String,
                    let x = entry["x"] as? Int, let y = entry["y"] as? Int,
                    let workspace = (entry["activeWorkspace"] as? [String: Any])?["id"] as? Int
                else { return nil }
                return Monitor(id: id, name: name, x: Double(x), y: Double(y), workspace: workspace)
            }
        }

        /// The monitor of the window with keyboard focus; nil without one.
        static func activeWindowMonitor() throws -> Int? {
            (try json("activewindow") as? [String: Any])?["monitor"] as? Int
        }

        /// The monitor with Hyprland's focus.
        static func focusedMonitor() throws -> Int? {
            let list = try #require(try json("monitors") as? [[String: Any]])
            return list.first { $0["focused"] as? Bool == true }?["id"] as? Int
        }

        /// The addresses (each `0x` and hex digits) of the windows on `monitor`, or on every
        /// monitor.
        static func windows(on monitor: Int? = nil) throws -> [String] {
            let clients = try #require(try json("clients") as? [[String: Any]])
            return clients.compactMap { client in
                guard monitor == nil || client["monitor"] as? Int == monitor,
                    let address = client["address"] as? String, address.wholeMatch(of: /0x[0-9a-f]+/) != nil
                else { return nil }
                return address
            }
        }

        static func windowCount(on monitor: Int) throws -> Int { try windows(on: monitor).count }

        /// Closes the windows the test opened, by address, those still open: never another.
        static func closeWindows(_ addresses: Set<String>) throws {
            for address in try windows() where addresses.contains(address) {
                _ = try run("hyprctl dispatch closewindow address:\(address)")
            }
        }

        static func cursor() throws -> (x: Double, y: Double) {
            let position = try #require(try json("cursorpos") as? [String: Any])
            return (try #require(position["x"] as? Double), try #require(position["y"] as? Double))
        }
    }

    /// One headless session over the shared connections (a virtual screen unless `screen`
    /// names another), with the app's own input rules (`InputController`) in front of it, as one
    /// window's capture. It keeps the stream, each second's frame rate and how it ended.
    final class LiveFocusScreen: Sendable {
        let session: Session
        let pointer = RemotePointerSlot()
        private let info = Mutex<StreamInfo?>(nil)
        private let rates = Mutex<[Double]>([])
        private let ended = Mutex<SessionEnd?>(nil)
        private let input = Mutex(InputController(keymap: ""))
        private let runner = Mutex<Task<Void, Never>?>(nil)

        init(
            connections: HostConnections, target: SSHTarget, screen: ScreenChoice = .virtual,
            maxSize: (width: Int, height: Int) = (1280, 720), clipboard: ClipboardSetup? = nil
        ) {
            let command = SSHCommand(target: target, serverArguments: screen.serverArguments)
            session = Session(
                transport: ChannelTransport(
                    connections: connections, target: target, command: command.remoteCommand),
                configuration: SessionConfiguration(
                    maxWidth: UInt32(maxSize.width), maxHeight: UInt32(maxSize.height),
                    keymap: XKBKeymap.text(for: XKBLayout(layout: "us"))),
                decoder: NullFrameDecoder(), pointer: pointer, clipboard: clipboard)
            let session = session
            runner.withLock {
                $0 = Task { [self] in
                    async let run: Void = session.run()
                    for await status in session.status {
                        switch status {
                        case .streaming(let streaming): self.info.withLock { $0 = streaming }
                        case .stats(let stats): self.rates.withLock { $0.append(stats.framesPerSecond) }
                        case .ended(let end): self.ended.withLock { $0 = end }
                        default: break
                        }
                    }
                    await run
                }
            }
        }

        /// The stream, once streaming; throws after 60 s without, or once the session ended.
        func streaming() async throws -> StreamInfo {
            for _ in 0..<600 {
                if let streaming = info.withLock({ $0 }) { return streaming }
                try #require(end == nil, "the session ended before streaming")
                try await Task.sleep(for: .milliseconds(100))
            }
            throw CancellationError()
        }

        /// Each second's frame rate so far.
        var framesPerSecond: [Double] { rates.withLock { $0 } }

        /// How the session ended; nil while it runs.
        var end: SessionEnd? { ended.withLock { $0 } }

        /// How the session ends by itself, waited for up to 30 s; nil if it runs on.
        func ending() async throws -> SessionEnd? {
            for _ in 0..<300 {
                if let end { return end }
                try await Task.sleep(for: .milliseconds(100))
            }
            return nil
        }

        var geometry: PictureGeometry? { info.withLock { $0 }?.pointerGeometry }

        /// The window's capture changes; what the rules say goes to the host.
        func capture(_ event: CaptureEvent) { send(input.withLock { $0.capture(event) }) }

        /// The window comes to the front: activation on the rising edge, as the app does, with
        /// the Mac pointer at `macPointer` over the picture (the remote's logical coordinates).
        func activate(at macPointer: (x: Double, y: Double)? = nil) throws {
            let geometry = try #require(geometry)
            let target = try #require(
                FocusTarget.target(
                    macPointer: macPointer, cursor: pointer.latest.map { ($0.x, $0.y) }, geometry: geometry))
            // As the app: the nudge before what capture turning on sends.
            let captured = input.withLock { controller in
                [CaptureEvent.appActive(true), .picture(true), .windowKey(true)].map {
                    controller.capture($0)
                }
            }
            send(input.withLock { $0.activate(at: target) })
            captured.forEach(send)
        }

        func key(_ code: UInt16, _ kind: MacKeyEvent.Kind, flags: MacModifierFlags = []) {
            send(input.withLock { $0.key(MacKeyEvent(keyCode: code, kind: kind, flags: flags.rawValue)) })
        }

        /// Super with `code`, pressed and released, through the rules.
        func chord(_ code: UInt16) {
            let held: MacModifierFlags = [.command, .leftCommand]
            key(55, .flagsChanged, flags: held)
            key(code, .down(isRepeat: false), flags: held)
            key(code, .up, flags: held)
            key(55, .flagsChanged)
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
