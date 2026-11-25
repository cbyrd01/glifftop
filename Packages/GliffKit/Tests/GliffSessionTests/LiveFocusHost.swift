#if os(macOS)
    import Foundation
    import Testing

    /// The host side of `LiveFocusTests`: `hyprctl` over the Mac's own ssh (`BatchMode`), read
    /// as JSON. Only numbers and ids are kept.
    enum LiveHyprland {
        enum Failure: Error {
            /// `hyprctl` (or ssh) exited with this status.
            case status(Int32)
            /// `hyprctl dispatch` answered something other than "ok" (its output isn't kept).
            case notOK
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

            /// The same monitor: by id and name, as Hyprland reuses ids.
            func isSame(as other: Monitor) -> Bool { id == other.id && name == other.name }
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

        /// The address of the window with keyboard focus; nil without one.
        static func activeWindow() throws -> String? {
            (try json("activewindow") as? [String: Any])?["address"] as? String
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
            return dispatchCommand(#"hl.dsp.window.close({ window = "address:"# + address + #"" })"#)
        }

        /// `hyprctl dispatch` of the Lua dispatcher `lua` (which holds no single quote).
        static func dispatchCommand(_ lua: String) -> String { "hyprctl dispatch '" + lua + "'" }

        /// Whether `hyprctl dispatch` answered that it ran the dispatcher.
        static func answeredOK(_ output: String) -> Bool {
            output.trimmingCharacters(in: .whitespacesAndNewlines) == "ok"
        }

        /// Runs each address's `closeCommand` through `run`, every one even after a failure;
        /// the failures. `hyprctl dispatch` answers "ok" when it ran the dispatcher, and exits
        /// nonzero on a Lua error; any other answer counts as a failure too.
        static func close(_ addresses: [String], with run: (String) throws -> String) -> [any Error] {
            addresses.compactMap(closeCommand).compactMap { command in
                do {
                    return answeredOK(try run(command)) ? nil : Failure.notOK
                } catch {
                    return error
                }
            }
        }

        /// Closes the windows the test opened, by address, those still open: never another.
        /// Then waits up to 2 s for them to go, and expects none left.
        static func closeWindows(_ addresses: Set<String>) async throws {
            let open = try windows().filter(addresses.contains)
            for failure in close(open, with: { try run($0, checked: true) }) {
                Issue.record(failure, "closing a window the test opened")
            }
            var left = addresses.intersection(try windows())
            for _ in 0..<20 where !left.isEmpty {
                try await Task.sleep(for: .milliseconds(100))
                left = addresses.intersection(try windows())
            }
            #expect(left.isEmpty, "\(left.count) windows the test opened are still open")
        }

        /// A terminal opened on `workspace`, leaving the focus where it is, that counts the
        /// keys typed into it in its title: "keys" and the count, from 0. The script goes as
        /// base64, so no quoting reaches the host's shells. It runs in Ghostty, which the host
        /// must have.
        static func openCounter(on workspace: Int) throws {
            try #require(
                !(try run("command -v ghostty")).isEmpty, "the key counter needs ghostty on the host")
            let script =
                #"n=0; printf '\033]2;keys %d\007' $n; "#
                + #"while IFS= read -rsn1 c; do n=$((n+1)); printf '\033]2;keys %d\007' $n; done"#
            let encoded = Data(script.utf8).base64EncodedString()
            let command = #"ghostty -e bash -c "$(echo "# + encoded + #" | base64 -d)""#
            let lua =
                "hl.dsp.exec_cmd([[" + command + #"]], { workspace = ""# + String(workspace) + #" silent" })"#
            guard answeredOK(try run(dispatchCommand(lua), checked: true)) else { throw Failure.notOK }
        }

        /// The keys a counter terminal (`openCounter`) at `address` has counted; nil unless its
        /// title is a counter's.
        static func counted(at address: String) throws -> Int? {
            let clients = try #require(try json("clients") as? [[String: Any]])
            let title = clients.first { $0["address"] as? String == address }?["title"] as? String
            guard let title, let match = title.wholeMatch(of: /keys (\d+)/) else { return nil }
            return Int(match.1)
        }

        /// The active workspace of `monitor`, if it is still there.
        static func activeWorkspace(on monitor: Monitor) throws -> Int? {
            try monitors().first { $0.isSame(as: monitor) }?.workspace
        }

        /// The host's pointer on `monitor`, logical.
        static func cursor(on monitor: Monitor) throws -> (x: Double, y: Double) {
            let position = try cursor()
            return (position.x - monitor.x, position.y - monitor.y)
        }

        /// The host's pointer in the layout, logical.
        static func cursor() throws -> (x: Double, y: Double) {
            let position = try #require(try json("cursorpos") as? [String: Any])
            return (try #require(position["x"] as? Double), try #require(position["y"] as? Double))
        }
    }
#endif
