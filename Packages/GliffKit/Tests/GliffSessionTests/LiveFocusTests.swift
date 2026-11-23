#if os(macOS)
    import Foundation
    import GliffInput
    import GliffSession
    import GliffTransport
    import Testing

    /// Input follows the window on top, against a real Hyprland host: two headless sessions (A
    /// and B, two virtual screens) over one ssh master, as two tabs to one machine are. Each
    /// opens a terminal on its screen (Super+Return), closed by address at the end. Off
    /// unless `GLIFFTOP_LIVE_HOST` names an ssh destination; it reports numbers and window
    /// counts only, as attachments.
    @Suite(
        .serialized, .timeLimit(.minutes(5)),
        .enabled(if: LiveHost.target != nil, "set GLIFFTOP_LIVE_HOST to run against a real server"))
    struct LiveFocusTests {
        static let returnKey: UInt16 = 36
        static let three: UInt16 = 20

        struct Pair {
            let a, b: LiveFocusScreen
            let monitorA, monitorB: LiveHyprland.Monitor
        }

        /// Starts A then B, finds each one's new monitor, opens a terminal on each (only with the
        /// host's focus on that screen), runs `body`, then closes what it opened, on every exit.
        func withTwoScreens(_ body: (Pair) async throws -> Void) async throws {
            let target = try SSHTarget(try #require(LiveHost.target))
            let connections = HostConnections(open: SystemSSH.opener())
            var screens: [(LiveFocusScreen, LiveHyprland.Monitor?)] = []
            var opened: Set<String> = []
            do {
                let before = Set(try LiveHyprland.monitors().map(\.name))
                for _ in 0..<2 {
                    let screen = LiveFocusScreen(connections: connections, target: target)
                    screens.append((screen, nil))
                    _ = try await screen.streaming()
                    let taken = Set(screens.compactMap(\.1?.name))
                    let monitor: LiveHyprland.Monitor = try #require(
                        try LiveHyprland.monitors().first {
                            !before.contains($0.name) && !taken.contains($0.name)
                        })
                    screens[screens.count - 1].1 = monitor
                }
                for (screen, monitor) in screens {
                    try screen.activate()
                    try await nap(0.5)
                    try #require(
                        try LiveHyprland.focusedMonitor() == monitor?.id, "focus never reached the screen")
                    let existing = Set(try LiveHyprland.windows())
                    screen.chord(Self.returnKey)
                    try await nap(2)
                    screen.capture(.windowKey(false))
                    opened.formUnion(
                        Set(try LiveHyprland.windows(on: try #require(monitor).id)).subtracting(existing))
                }
                try await body(
                    Pair(
                        a: screens[0].0, b: screens[1].0, monitorA: try #require(screens[0].1),
                        monitorB: try #require(screens[1].1)))
            } catch {
                await close(screens, opened, connections)
                throw error
            }
            await close(screens, opened, connections)
        }

        private func close(
            _ screens: [(LiveFocusScreen, LiveHyprland.Monitor?)], _ opened: Set<String>,
            _ connections: HostConnections
        ) async {
            for (screen, _) in screens { screen.capture(.windowKey(false)) }
            // A terminal mapped late is still on the test's own screen: its monitor, rechecked
            // by name too, since Hyprland reuses ids.
            var closing = opened
            let current = (try? LiveHyprland.monitors()) ?? []
            for case (_, let monitor?) in screens
            where current.contains(where: { $0.id == monitor.id && $0.name == monitor.name }) {
                closing.formUnion((try? LiveHyprland.windows(on: monitor.id)) ?? [])
            }
            try? LiveHyprland.closeWindows(closing)
            try? await nap(1)
            for (screen, _) in screens { await screen.end() }
            await connections.closeAll()
        }

        private func nap(_ seconds: Double) async throws { try await Task.sleep(for: .seconds(seconds)) }

        @Test func activationMovesTheHostsFocus() async throws {
            try await withTwoScreens { pair in
                try pair.a.activate()
                try await nap(0.5)
                let onA = try LiveHyprland.activeWindowMonitor()
                pair.a.capture(.windowKey(false))
                try pair.b.activate()
                try await nap(0.5)
                let onB = try LiveHyprland.activeWindowMonitor()
                pair.b.capture(.windowKey(false))
                Attachment.record(
                    "windows A \(try LiveHyprland.windowCount(on: pair.monitorA.id)) B "
                        + "\(try LiveHyprland.windowCount(on: pair.monitorB.id)); focus after A \(onA == pair.monitorA.id), "
                        + "after B \(onB == pair.monitorB.id)",
                    named: "live-focus-activation.txt")
                #expect(onA == pair.monitorA.id)
                #expect(onB == pair.monitorB.id)
            }
        }

        @Test func cursorPositionMatchesHyprland() async throws {
            try await withTwoScreens { pair in
                try pair.a.activate()
                try await nap(1)
                let latest = try #require(pair.a.pointer.latest)
                let geometry = try #require(pair.a.geometry)
                let logical = try #require(
                    FocusTarget.logical(bufferX: latest.x, bufferY: latest.y, geometry: geometry))
                let host = try LiveHyprland.cursor()
                let dx = abs(logical.x - (host.x - pair.monitorA.x))
                let dy = abs(logical.y - (host.y - pair.monitorA.y))
                pair.a.capture(.windowKey(false))
                try pair.b.activate()
                try await nap(1)
                let hidden = pair.a.pointer.latest?.visible == false
                pair.b.capture(.windowKey(false))
                Attachment.record(
                    "cursor dx \(dx) dy \(dy) visible \(latest.visible); A hidden after B \(hidden)",
                    named: "live-focus-cursor.txt")
                #expect(dx <= 1 && dy <= 1)
                #expect(hidden)
            }
        }

        @Test func aSwitchWhileSuperIsHeldTypesNoDigit() async throws {
            try await withTwoScreens { pair in
                let workspace = { try LiveHyprland.monitors().first { $0.id == pair.monitorB.id }?.workspace }
                let before = try workspace()
                try pair.a.activate()
                pair.a.key(55, .flagsChanged, flags: [.command, .leftCommand])
                try await nap(0.3)
                // A resigns key with Super held: its release goes out before B is activated.
                pair.a.capture(.windowKey(false))
                try pair.b.activate()
                pair.b.key(Self.three, .down(isRepeat: false))
                pair.b.key(Self.three, .up)
                try await nap(0.8)
                let after = try workspace()
                pair.b.capture(.windowKey(false))
                Attachment.record("B workspace unchanged \(before == after)", named: "live-focus-super.txt")
                #expect(before == after)
            }
        }

        /// Both screens' sessions on one master: ssh processes this test started as masters.
        @Test func oneMaster() async throws {
            try await withTwoScreens { _ in
                let masters = try Self.masters()
                Attachment.record("masters \(masters)", named: "live-focus-masters.txt")
                #expect(masters == 1)
            }
        }

        /// The ssh masters whose parent is this process.
        static func masters() throws -> Int {
            let ps = Process()
            ps.executableURL = URL(filePath: "/bin/ps")
            ps.arguments = ["-axww", "-o", "ppid=,args="]
            let out = Pipe()
            ps.standardOutput = out
            try ps.run()
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            ps.waitUntilExit()
            let me = String(getpid())
            return text.split(separator: "\n").count { line in
                let fields = line.split(separator: " ", maxSplits: 1)
                return fields.first.map(String.init) == me && line.contains("ControlMaster=yes")
            }
        }
    }
#endif
