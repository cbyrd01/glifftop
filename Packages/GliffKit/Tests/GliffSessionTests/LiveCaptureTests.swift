#if os(macOS)
    import Foundation
    import GliffProtocol
    import GliffSession
    import Testing

    @testable import GliffInput

    /// Capture mode and the modifiers against a real Hyprland host: the server's rounding and
    /// clamp of motions, a workspace change's warp followed, Super held for a ⌘-scroll, whether
    /// a key hides the host's pointer, and the Super race through the barrier. Headless virtual
    /// screens (`LiveScreens`), each terminal closed by address at the end. Off unless
    /// `GLIFFTOP_LIVE_HOST` names an ssh destination; it reports numbers only, as attachments.
    @Suite(
        .serialized, .timeLimit(.minutes(5)),
        .enabled(if: LiveHost.target != nil, "set GLIFFTOP_LIVE_HOST to run against a real server"))
    struct LiveCaptureTests {
        @Test func theServerRoundsAndClampsAsModelled() async throws {
            try await LiveScreens.with(1, terminals: false) { screens in
                let (screen, monitor) = (screens[0].screen, screens[0].monitor)
                let geometry = try #require(screen.geometry)
                let size = try #require(geometry.logicalSize)
                var lines: [String] = []
                var mismatches = 0
                let points: [(x: Double, y: Double)] =
                    [100.4, 100.5, 100.6, -50, size.width + 50].map { ($0, 200) }
                    + [100.4, 100.5, 100.6, -50, size.height + 50].map { (300, $0) }
                for point in points {
                    screen.session.send(.pointerMotion(x: point.x, y: point.y))
                    try await LiveScreens.nap(0.3)
                    let host = try LiveHyprland.cursor(on: monitor)
                    let model = (
                        VirtualPointer.applied(point.x, extent: size.width),
                        VirtualPointer.applied(point.y, extent: size.height)
                    )
                    if host != model { mismatches += 1 }
                    lines.append(
                        "sent \(point.x) \(point.y) host \(host.x) \(host.y) model \(model.0) \(model.1)")
                }
                Attachment.record(lines.joined(separator: "\n"), named: "live-capture-rounding.txt")
                #expect(mismatches == 0)
            }
        }

        @Test func aWorkspaceWarpIsAdopted() async throws {
            try await LiveScreens.with(1, mode: .confined) { screens in
                let (screen, monitor) = (screens[0].screen, screens[0].monitor)
                try screen.activate()
                try await LiveScreens.nap(0.5)
                let workspace = try LiveHyprland.activeWorkspace(on: monitor)
                try screen.confine()
                // Hyprland warps on a workspace change only from a pointer over a window: a
                // terminal on the second workspace too, the pointer over it, off the first
                // terminal's middle.
                try await LiveScreens.terminalOnSecondWorkspace(screens[0])
                _ = try screen.followHost()
                let off = try #require(screen.confinedPointer)
                screen.delta(dx: 100 - off.x, dy: 100 - off.y)
                try await LiveScreens.nap(0.3)
                _ = try screen.followHost()
                screen.chord(LiveScreens.one)
                try await LiveScreens.nap(0.5)
                let warped = try screen.followHost()
                let back = try LiveHyprland.activeWorkspace(on: monitor)
                let followed = try #require(screen.confinedPointer)
                let host = try LiveHyprland.cursor(on: monitor)
                let sent = screen.delta(dx: 10, dy: 0)
                let dx = abs(followed.x - host.x)
                let dy = abs(followed.y - host.y)
                Attachment.record(
                    "warp adopted \(warped); back on the workspace \(back == workspace); dx \(dx) dy \(dy)",
                    named: "live-capture-warp.txt")
                #expect(back == workspace)
                #expect(warped)
                #expect(dx <= 1 && dy <= 1)
                #expect(sent.last == .pointerMotion(x: followed.x + 10, y: followed.y))
            }
        }

        @Test func aScrollWithCommandHoldsSuper() async throws {
            try await LiveScreens.with(1) { screens in
                let (screen, monitor) = (screens[0].screen, screens[0].monitor)
                try screen.activate()
                try await LiveScreens.nap(0.5)
                // A terminal on the second workspace too, then back on the first.
                try await LiveScreens.terminalOnSecondWorkspace(screens[0])
                screen.chord(LiveScreens.one)
                try await LiveScreens.nap(0.5)
                let first = try LiveHyprland.activeWorkspace(on: monitor)
                let command = LiveScreens.superHeld
                screen.scroll(down: true, flags: command)
                try await LiveScreens.nap(0.5)
                let scrolled = try LiveHyprland.activeWorkspace(on: monitor)
                screen.scroll(down: false, flags: command)
                try await LiveScreens.nap(0.5)
                let back = try LiveHyprland.activeWorkspace(on: monitor)
                screen.scroll(down: true)
                try await LiveScreens.nap(0.5)
                let plain = try LiveHyprland.activeWorkspace(on: monitor)
                Attachment.record(
                    "⌘-scroll changed \(scrolled != first); back \(back == first); plain scroll kept \(plain == first)",
                    named: "live-capture-scroll.txt")
                #expect(scrolled != first)
                #expect(back == first)
                #expect(plain == first)
            }
        }

        /// No expectation: the design holds whether or not a key hides the host's pointer.
        @Test func hideOnKeyPressIsRecorded() async throws {
            try await LiveScreens.with(1) { screens in
                let screen = screens[0].screen
                try screen.activate()
                try await LiveScreens.nap(0.5)
                _ = screen.reports()
                screen.key(0x00, .down(isRepeat: false))
                screen.key(0x00, .up)
                var hidden = false
                for _ in 0..<25 where !hidden {
                    try await LiveScreens.nap(0.02)
                    hidden = screen.reports().contains { $0?.visible == false }
                }
                Attachment.record(hidden ? "1" : "0", named: "live-hide-on-key.txt")
            }
        }

        @Test func theBarrierStopsTheSuperRace() async throws {
            let barrier = InputBarrier(clock: ContinuousClock())
            try await LiveScreens.with(2, barrier: barrier) { screens in
                let (a, b, monitorB) = (screens[0].screen, screens[1].screen, screens[1].monitor)
                try a.activate()
                try b.activate()
                try await LiveScreens.nap(0.5)
                var last = try LiveHyprland.activeWorkspace(on: monitorB)
                var changes = 0
                for round in 0..<50 {
                    a.key(LiveScreens.superKey, .flagsChanged, flags: LiveScreens.superHeld)
                    a.key(LiveScreens.superKey, .flagsChanged)
                    let digit = round.isMultiple(of: 2) ? LiveScreens.two : LiveScreens.three
                    b.key(digit, .down(isRepeat: false))
                    b.key(digit, .up)
                    try await LiveScreens.nap(0.15)
                    let now = try LiveHyprland.activeWorkspace(on: monitorB)
                    if now != last { changes += 1 }
                    last = now
                }
                Attachment.record("B's workspace changed in \(changes) of 50", named: "live-barrier-race.txt")
                #expect(changes == 0)
            }
        }
    }
#endif
