#if os(macOS)
    import Foundation
    import GliffInput
    import GliffSession
    import GliffTransport
    import Synchronization
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
        struct Pair {
            let a, b: LiveFocusScreen
            let monitorA, monitorB: LiveHyprland.Monitor
        }

        /// Two screens with a terminal each (`LiveScreens.with`), sharing a barrier as the app's
        /// tabs do.
        func withTwoScreens(_ body: (Pair) async throws -> Void) async throws {
            try await LiveScreens.with(2, barrier: InputBarrier(clock: ContinuousClock())) { screens in
                try await body(
                    Pair(
                        a: screens[0].screen, b: screens[1].screen, monitorA: screens[0].monitor,
                        monitorB: screens[1].monitor))
            }
        }

        @Test func activationMovesTheHostsFocus() async throws {
            try await withTwoScreens { pair in
                try pair.a.activate()
                try await LiveScreens.nap(0.5)
                let onA = try LiveHyprland.activeWindowMonitor()
                pair.a.capture(.windowKey(false))
                try pair.b.activate()
                try await LiveScreens.nap(0.5)
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
                try await LiveScreens.nap(1)
                let latest = try #require(pair.a.pointer.latest)
                let geometry = try #require(pair.a.geometry)
                let logical = try #require(
                    FocusTarget.logical(bufferX: latest.x, bufferY: latest.y, geometry: geometry))
                let host = try LiveHyprland.cursor(on: pair.monitorA)
                let dx = abs(logical.x - host.x)
                let dy = abs(logical.y - host.y)
                pair.a.capture(.windowKey(false))
                try pair.b.activate()
                try await LiveScreens.nap(1)
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
                let workspace = { try LiveHyprland.activeWorkspace(on: pair.monitorB) }
                let before = try workspace()
                try pair.a.activate()
                pair.a.key(LiveScreens.superKey, .flagsChanged, flags: LiveScreens.superHeld)
                try await LiveScreens.nap(0.3)
                // A resigns key with Super held: its release goes out before B is activated.
                pair.a.capture(.windowKey(false))
                try pair.b.activate()
                pair.b.key(LiveScreens.three, .down(isRepeat: false))
                pair.b.key(LiveScreens.three, .up)
                try await LiveScreens.nap(0.8)
                let after = try workspace()
                pair.b.capture(.windowKey(false))
                Attachment.record("B workspace unchanged \(before == after)", named: "live-focus-super.txt")
                #expect(before == after)
            }
        }

        /// The host's side of a tab switch by keys: ⇧⌘ held on the screen in front (a tab
        /// chord's), its window resigning, the other activated at the Mac pointer's place over
        /// its terminal, and a key at once, three times each way: the focus is on that terminal
        /// after each key. Each host pointer starts over its screen's bar, where an activation
        /// at the host's own place leaves the focus behind. (Finding the Mac pointer at a switch
        /// is the app's: a hand check.) The key's delivery isn't read back: the barrier's own
        /// case (`aSwitchWhileSuperIsHeldTypesNoDigit`) covers a key read with Super held.
        @Test func aSwitchByKeysTypesIntoTheScreenInFront() async throws {
            try await withTwoScreens { pair in
                let size = try #require(pair.a.geometry?.logicalSize)
                let overTerminal = (x: size.width / 2, y: size.height / 2)
                for screen in [pair.a, pair.b] {
                    try screen.activate(macPointer: (12, 7))
                    try await LiveScreens.nap(0.3)
                    screen.capture(.windowKey(false))
                }
                try pair.b.activate(macPointer: overTerminal)
                try await LiveScreens.nap(0.3)
                var landed = 0
                let chord = LiveScreens.superHeld.union(LiveScreens.shiftHeld)
                for round in 0..<6 {
                    let (from, to) = round.isMultiple(of: 2) ? (pair.b, pair.a) : (pair.a, pair.b)
                    from.key(LiveScreens.superKey, .flagsChanged, flags: LiveScreens.superHeld)
                    from.key(LiveScreens.shiftKey, .flagsChanged, flags: chord)
                    from.capture(.windowKey(false))
                    try to.activate(macPointer: overTerminal)
                    to.key(LiveScreens.shiftKey, .flagsChanged, flags: LiveScreens.superHeld)
                    to.key(LiveScreens.superKey, .flagsChanged)
                    to.key(LiveScreens.xKey, .down(isRepeat: false))
                    to.key(LiveScreens.xKey, .up)
                    try await LiveScreens.nap(0.5)
                    let active = try LiveHyprland.activeWindow()
                    if let active, to.opened.withLock({ $0.contains(active) }) { landed += 1 }
                }
                Attachment.record(
                    "keys on the screen in front \(landed) of 6", named: "live-focus-switch.txt")
                #expect(landed == 6)
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
