#if os(macOS)
    import Foundation
    import GliffInput
    import GliffSession
    import GliffTransport
    import Synchronization
    import Testing

    /// Headless screens for the live suites: sessions over one ssh master, each on its own new
    /// virtual screen, each with a terminal. Only windows that appeared on the test's own screens
    /// are closed, by address: never one that was open before the test.
    enum LiveScreens {
        /// Left ⌘, Super on the host, and the flags it holds.
        static let superKey: UInt16 = 55
        static let superHeld: MacModifierFlags = [.command, .leftCommand]
        /// Left Shift, and the flags it holds.
        static let shiftKey: UInt16 = 56
        static let shiftHeld: MacModifierFlags = [.shift, .leftShift]
        /// Mac key codes: U (no binding of the host's has it), E, Return, and the digits 1, 2
        /// and 3.
        static let uKey: UInt16 = 32
        static let eKey: UInt16 = 14
        static let returnKey: UInt16 = 36
        static let one: UInt16 = 18
        static let two: UInt16 = 19
        static let three: UInt16 = 20

        struct Screen {
            let screen: LiveFocusScreen
            let monitor: LiveHyprland.Monitor
        }

        /// How long, in milliseconds, a burst of switches took to be written from `start`, and the
        /// longest a switch waited: from one session's last write to the other's first.
        static func switchHolds(
            after start: ContinuousClock.Instant, _ a: RecordingObserver, _ b: RecordingObserver
        ) -> (total: Int, longest: Int) {
            func input(_ observer: RecordingObserver, _ screen: Int) -> [(ContinuousClock.Instant, Int)] {
                observer.events.filter {
                    $0.direction == .sent && ($0.type == "Key" || $0.type == "PointerMotion")
                        && $0.time >= start
                }.map { ($0.time, screen) }
            }
            let writes = (input(a, 0) + input(b, 1)).sorted { $0.0 < $1.0 }
            let ms = { (d: Duration) in Int(d / .milliseconds(1)) }
            let longest =
                zip(writes, writes.dropFirst()).filter { $0.1 != $1.1 }.map { ms($1.0 - $0.0) }.max() ?? 0
            return (writes.last.map { ms($0.0 - start) } ?? 0, longest)
        }

        /// Starts `count` screens one after the other (the input rules in `mode`, sessions
        /// sharing `barrier`), finds each one's new monitor, opens a terminal on each with
        /// `terminals` (Super+Return, only with the host's focus on that screen), runs `body`,
        /// then closes what appeared on the screens, on every exit.
        static func with(
            _ count: Int, mode: CaptureMode = .integrated, barrier: InputBarrier? = nil,
            terminals: Bool = true, largest: (width: UInt32, height: UInt32) = (1280, 720),
            _ body: ([Screen]) async throws -> Void
        ) async throws {
            let target = try SSHTarget(try #require(LiveHost.target))
            let connections = HostConnections(open: SystemSSH.opener())
            // Every session started, ended even if its monitor is never found.
            var started: [LiveFocusScreen] = []
            var screens: [Screen] = []
            let before = Set(try LiveHyprland.windows())
            do {
                let monitorsBefore = Set(try LiveHyprland.monitors().map(\.name))
                for _ in 0..<count {
                    let screen = LiveFocusScreen(
                        connections: connections, target: target, mode: mode, barrier: barrier,
                        largest: largest)
                    started.append(screen)
                    _ = try await screen.streaming()
                    let taken = Set(screens.map(\.monitor.name))
                    let monitor = try #require(
                        try LiveHyprland.monitors().first {
                            !monitorsBefore.contains($0.name) && !taken.contains($0.name)
                        })
                    screens.append(Screen(screen: screen, monitor: monitor))
                }
                if terminals {
                    for screen in screens {
                        try screen.screen.activate()
                        try await nap(0.5)
                        try await openTerminal(screen)
                        screen.screen.capture(.windowKey(false))
                    }
                }
                try await body(screens)
            } catch {
                await close(started, screens, before, connections)
                throw error
            }
            await close(started, screens, before, connections)
        }

        /// A terminal on `screen`'s workspace in front (Super+Return, only with the host's focus
        /// on that screen), given 2 s to map, and recorded.
        static func openTerminal(_ screen: Screen) async throws {
            try requireFocus(on: screen, "focus never reached the screen")
            let before = Set(try LiveHyprland.windows(on: screen.monitor.id))
            screen.screen.chord(returnKey)
            try await nap(2)
            try recordNew(on: screen, since: before)
        }

        /// The windows on `screen`'s monitor that aren't in `before`, recorded to close at the end.
        @discardableResult
        private static func recordNew(on screen: Screen, since before: Set<String>) throws -> Set<String> {
            let opened = Set(try LiveHyprland.windows(on: screen.monitor.id)).subtracting(before)
            screen.screen.opened.withLock { $0.formUnion(opened) }
            return opened
        }

        /// A key-counting terminal (`LiveHyprland.openCounter`) on `screen`'s workspace in front,
        /// given 5 s to map and show its count, and recorded; its address.
        static func openCounter(_ screen: Screen) async throws -> String {
            let workspace = try #require(try LiveHyprland.activeWorkspace(on: screen.monitor))
            let before = Set(try LiveHyprland.windows(on: screen.monitor.id))
            try LiveHyprland.openCounter(on: workspace)
            var counter: String?
            for _ in 0..<50 where counter == nil {
                try await nap(0.1)
                let opened = try recordNew(on: screen, since: before)
                if opened.count == 1, let address = opened.first, try LiveHyprland.counted(at: address) == 0 {
                    counter = address
                }
            }
            return try #require(counter, "no counter terminal showed its count on the screen")
        }

        /// A terminal on `screen`'s second workspace (Super+2), which stays in front. The host's
        /// Super+digit must keep to the screen (omarchy gives each monitor its own workspaces).
        static func terminalOnSecondWorkspace(_ screen: Screen) async throws {
            screen.screen.chord(two)
            try await nap(0.5)
            try requireFocus(on: screen, "Super+2 left the test's screen: its workspaces aren't per monitor")
            try await openTerminal(screen)
        }

        private static func requireFocus(on screen: Screen, _ comment: Comment) throws {
            try #require(try LiveHyprland.focusedMonitor() == screen.monitor.id, comment)
        }

        private static func close(
            _ started: [LiveFocusScreen], _ screens: [Screen], _ before: Set<String>,
            _ connections: HostConnections
        ) async {
            for screen in started { screen.capture(.windowKey(false)) }
            // The windows the test opened, and any others on its own screens (its monitors, if
            // still there) that weren't open before it.
            var closing = screens.reduce(into: Set<String>()) { set, screen in
                screen.screen.opened.withLock { set.formUnion($0) }
            }
            let current = (try? LiveHyprland.monitors()) ?? []
            for monitor in screens.map(\.monitor)
            where current.contains(where: { $0.isSame(as: monitor) }) {
                closing.formUnion((try? LiveHyprland.windows(on: monitor.id)) ?? [])
            }
            do {
                try await LiveHyprland.closeWindows(closing.subtracting(before))
            } catch {
                Issue.record(error, "closing the test's windows")
            }
            try? await nap(1)
            for screen in started { await screen.end() }
            await connections.closeAll()
        }

        static func nap(_ seconds: Double) async throws { try await Task.sleep(for: .seconds(seconds)) }
    }
#endif
