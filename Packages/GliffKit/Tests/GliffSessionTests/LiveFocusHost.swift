#if os(macOS)
    import Foundation
    import GliffInput
    import GliffSession
    import GliffTransport
    import GliffVideo
    import Synchronization
    import Testing

    /// The host side of `LiveFocusTests`: `hyprctl` over the Mac's own ssh (`BatchMode`), read
    /// as JSON. Only numbers and ids are kept.
    enum LiveHyprland {
        enum Failure: Error {
            /// `hyprctl` (or ssh) exited with this status.
            case status(Int32)
        }

        /// `script` on the host, its output; with `checked`, a nonzero exit throws.
        static func run(_ script: String, checked: Bool = false) throws -> String {
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
            if checked, process.terminationStatus != 0 { throw Failure.status(process.terminationStatus) }
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
                    let address = client["address"] as? String, isAddress(address)
                else { return nil }
                return address
            }
        }

        static func windowCount(on monitor: Int) throws -> Int { try windows(on: monitor).count }

        /// A window address as `hyprctl` gives it: `0x` and lowercase hex digits.
        static func isAddress(_ text: String) -> Bool { text.wholeMatch(of: /0x[0-9a-f]+/) != nil }

        /// Hyprland's Lua dispatcher closing the window at `address`; nil unless `address` is
        /// `0x` and lowercase hex digits, as `hyprctl` gives them.
        static func closeCommand(address: String) -> String? {
            guard isAddress(address) else { return nil }
            return #"hyprctl dispatch 'hl.dsp.window.close({ window = "address:"# + address + #"" })'"#
        }

        /// Runs each address's `closeCommand` through `run`, every one even after a failure;
        /// the failures.
        static func close(_ addresses: [String], with run: (String) throws -> Void) -> [any Error] {
            addresses.compactMap(closeCommand).compactMap { command in
                do {
                    try run(command)
                    return nil
                } catch {
                    return error
                }
            }
        }

        /// Closes the windows the test opened, by address, those still open: never another.
        /// Then waits up to 2 s for them to go, and expects none left.
        static func closeWindows(_ addresses: Set<String>) async throws {
            let open = try windows().filter(addresses.contains)
            for failure in close(open, with: { _ = try run($0, checked: true) }) {
                Issue.record(failure, "closing a window the test opened")
            }
            var left = addresses.intersection(try windows())
            for _ in 0..<20 where !left.isEmpty {
                try await Task.sleep(for: .milliseconds(100))
                left = addresses.intersection(try windows())
            }
            #expect(left.isEmpty, "\(left.count) windows the test opened are still open")
        }

        static func cursor() throws -> (x: Double, y: Double) {
            let position = try #require(try json("cursorpos") as? [String: Any])
            return (try #require(position["x"] as? Double), try #require(position["y"] as? Double))
        }
    }

    /// One headless session over the shared connections, with the app's own input rules
    /// (`InputController`) in front of it, as one window's capture.
    final class LiveFocusScreen: Sendable {
        let session: Session
        let pointer = RemotePointerSlot()
        private let info = Mutex<StreamInfo?>(nil)
        private let input = Mutex(InputController(keymap: ""))
        private let runner = Mutex<Task<Void, Never>?>(nil)

        init(connections: HostConnections, target: SSHTarget) {
            let command = SSHCommand(target: target, serverArguments: ScreenChoice.virtual.serverArguments)
            session = Session(
                transport: ChannelTransport(
                    connections: connections, target: target, command: command.remoteCommand),
                configuration: SessionConfiguration(
                    maxWidth: 1280, maxHeight: 720, keymap: XKBKeymap.text(for: XKBLayout(layout: "us"))),
                decoder: NullFrameDecoder(), pointer: pointer)
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

        /// The window comes to the front: activation on the rising edge, as the app does.
        func activate() throws {
            let geometry = try #require(geometry)
            let target = try #require(
                FocusTarget.target(
                    macPointer: nil, cursor: pointer.latest.map { ($0.x, $0.y) }, geometry: geometry))
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
