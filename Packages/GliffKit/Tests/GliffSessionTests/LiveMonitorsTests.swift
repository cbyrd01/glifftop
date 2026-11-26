#if os(macOS)
    import Foundation
    import GliffClipboard
    import GliffInput
    import GliffMachines
    import GliffSession
    import GliffTransport
    import Synchronization
    import Testing

    /// Several monitors against a real Hyprland host (`LiveHost`): positions, every monitor
    /// mirrored at once, the activation nudge across two mirrors, the clipboard handed over
    /// between two virtual screens, and a mirrored output that goes away. The mirrors of the
    /// host's real monitors (checks 2 and 3) are held under a minute together and send motion
    /// only; each check that can move the host's pointer or focus puts both back with a nudge at
    /// the recorded `cursorpos`. Only numbers are reported, as `live-monitors-*.txt`.
    @Suite(
        .serialized, .timeLimit(.minutes(5)),
        .enabled(if: LiveHost.target != nil, "set GLIFFTOP_LIVE_HOST to run against a real server"))
    struct LiveMonitorsTests {
        let target: SSHTarget
        let connections = HostConnections(open: SystemSSH.opener())

        init() throws { target = try SSHTarget(try #require(LiveHost.target)) }

        @Test func positionsMatchHyprctl() async throws {
            let screens = try await listed()
            let monitors = try LiveHyprland.monitors()
            await connections.closeAll()
            let matched = screens.filter { screen in
                monitors.contains { $0.name == screen.name && Int($0.x) == screen.x && Int($0.y) == screen.y }
            }
            let layout = monitors.filter { monitor in screens.contains { $0.name == monitor.name } }
                .sorted { ($0.x, $0.y, $0.name) < ($1.x, $1.y, $1.name) }.map(\.name)
            let inOrder = MonitorPlanning.hostOrder(screens).map(\.name) == layout
            Attachment.record(
                "listed \(screens.count), positions matched \(matched.count), host order matches \(inOrder ? 1 : 0)",
                named: "live-monitors-positions.txt")
            #expect(!screens.isEmpty)
            #expect(matched.count == screens.count)
            #expect(inOrder)
        }

        @Test func everyMonitorStreamsAtOnce() async throws {
            let screens = try await listed()
            let before = try LiveHyprland.monitors().map { "\($0.name) \($0.workspace)" }
            let start = try PutBack.record()
            let mirrors = screens.map { mirror(of: $0) }
            var sized = 0
            var rates: [Double] = []
            let run: Result<Void, any Error> = await caught {
                for (mirror, screen) in zip(mirrors, screens) {
                    let info = try await mirror.streaming()
                    if Int(info.width) == screen.width && Int(info.height) == screen.height { sized += 1 }
                }
                try await nap(15)
                rates = mirrors.map {
                    $0.framesPerSecond.reduce(0, +) / Double(max($0.framesPerSecond.count, 1))
                }
            }
            let pointer = try? await start.restore(through: mirrors, screens: screens) { mirror(of: $0) }
            for mirror in mirrors { await mirror.end() }
            await connections.closeAll()
            try run.get()
            let ended = mirrors.filter { $0.end == .disconnected }.count
            let after = try LiveHyprland.monitors().map { "\($0.name) \($0.workspace)" }
            Attachment.record(
                """
                monitors \(screens.count), sized as their monitor \(sized), ended with Bye \(ended)
                mean fps (a still desktop sends none) \(rates.map { String(format: "%.1f", $0) }.joined(separator: " "))
                layout unchanged \(before == after ? 1 : 0), pointer put back \(pointer == true ? 1 : 0)
                """,
                named: "live-monitors-all.txt")
            #expect(sized == screens.count)
            #expect(ended == screens.count)
            #expect(before == after)
            #expect(pointer == true)
        }

        @Test func theNudgeLandsOnEachMirror() async throws {
            // Every monitor, for the put-back; the first two mirrored.
            let all = MonitorPlanning.hostOrder(try await listed())
            try #require(all.count >= 2, "needs two monitors")
            let screens = Array(all.prefix(2))
            let monitors = try LiveHyprland.monitors()
            let start = try PutBack.record()
            let mirrors = screens.map { mirror(of: $0) }
            var landed: [String] = []
            let run: Result<Void, any Error> = await caught {
                for mirror in mirrors { _ = try await mirror.streaming() }
                // B, then A, each with the other's input released.
                for (index, point) in [(1, (x: 100.0, y: 100.0)), (0, (x: 200.0, y: 150.0))] {
                    let monitor = try #require(monitors.first { $0.name == screens[index].name })
                    try mirrors[index].activate(macPointer: point)
                    try await nap(0.7)
                    let cursor = try LiveHyprland.cursor()
                    let near =
                        abs(cursor.x - (monitor.x + point.x)) <= 1
                        && abs(cursor.y - (monitor.y + point.y)) <= 1
                    let focused = try LiveHyprland.focusedMonitor() == monitor.id
                    landed.append(
                        "\(index == 1 ? "B" : "A") within 1 px \(near ? 1 : 0), focused \(focused ? 1 : 0)")
                    mirrors[index].capture(.windowKey(false))
                }
            }
            let pointer = try? await start.restore(through: mirrors, screens: all) { mirror(of: $0) }
            for mirror in mirrors { await mirror.end() }
            await connections.closeAll()
            try run.get()
            Attachment.record(
                landed.joined(separator: "\n") + "\npointer put back \(pointer == true ? 1 : 0)",
                named: "live-monitors-nudge.txt")
            #expect(landed == ["B within 1 px 1, focused 1", "A within 1 px 1, focused 1"])
            #expect(pointer == true)
        }

        @Test func theClipboardIsHandedOver() async throws {
            let marker = LiveClipboardTests.marker()
            let sources = [ReadCounter(Array(marker.utf8)), ReadCounter(Array(marker.utf8))]
            let screens = sources.map {
                LiveFocusScreen(
                    connections: connections, target: target, clipboard: ClipboardSetup(source: $0))
            }
            let (a, b) = (UUID(), UUID())
            var ledger = HostClipboardLedger()
            ledger.register(a, host: target.value, sharing: true)
            ledger.register(b, host: target.value, sharing: true)
            var results: [String] = []
            let run: Result<Void, any Error> = await caught {
                for screen in screens { _ = try await screen.streaming() }
                // A offers this Mac copy (change count 1); the host takes it.
                _ = ledger.offered(a, changeCount: 1, at: .seconds(1))
                screens[0].session.offerClipboard(Self.offer)
                let first = try await Self.paste(until: marker)
                let readsA = sources[0].reads
                // B comes to the front: the copy is A's, so B offers nothing.
                ledger.front(b, at: .seconds(2))
                let held = ledger.heldElsewhere(b, changeCount: 1)
                if !held { screens[1].session.offerClipboard(Self.offer) }
                try await nap(2)
                let quiet = sources[0].reads == readsA && sources[1].reads == 0
                // A's window closes: B takes the copy over, then A's server ends.
                let handovers = ledger.detaching([a], macCount: 1)
                let offersB = handovers.first?.candidates.first == b
                if offersB {
                    _ = ledger.offered(b, changeCount: 1, at: .seconds(3))
                    screens[1].session.offerClipboard(Self.offer)
                }
                await screens[0].end()
                try await nap(1)
                let second = try await Self.paste(until: marker)
                results = [
                    "A pasted \(first ? 1 : 0)", "held elsewhere on B's front \(held ? 1 : 0)",
                    "no second read \(quiet ? 1 : 0)", "B offered on A's end \(offersB ? 1 : 0)",
                    "pasted after A ended \(second ? 1 : 0)", "B read \(sources[1].reads > 0 ? 1 : 0)",
                ]
            }
            for screen in screens { await screen.end() }
            await connections.closeAll()
            try run.get()
            Attachment.record(results.joined(separator: "\n"), named: "live-monitors-clipboard.txt")
            #expect(results.allSatisfy { $0.hasSuffix(" 1") })
        }

        @Test func aGoneOutputEndsItsMirror() async throws {
            let start = try PutBack.record()
            let before = Set(try LiveHyprland.monitors().map(\.name))
            let virtual = LiveFocusScreen(connections: connections, target: target)
            var mirrors: [LiveFocusScreen] = []
            var results: [String] = []
            let run: Result<Void, any Error> = await caught {
                _ = try await virtual.streaming()
                let name = try #require(try LiveHyprland.monitors().first { !before.contains($0.name) }?.name)
                let mirror = LiveFocusScreen(connections: connections, target: target, screen: .named(name))
                mirrors.append(mirror)
                _ = try await mirror.streaming()
                await virtual.end()
                let end = try await mirror.ending()
                let again = LiveFocusScreen(connections: connections, target: target, screen: .named(name))
                mirrors.append(again)
                let missing = try await again.ending()?.isMissingMonitor(.named(name)) == true
                results = [
                    "mirror ended \(end == nil ? 0 : 1), as a lost link \(end == .connectionLost ? 1 : 0)",
                    "a new mirror finds it missing \(missing ? 1 : 0)",
                ]
            }
            await virtual.end()
            for mirror in mirrors { await mirror.end() }
            // Closing the virtual screen moves the host's focus: one mirror of the monitor that
            // had it, for a nudge at the recorded position.
            let screens = (try? await listed()) ?? []
            let pointer = try? await start.restore(through: [], screens: screens) { mirror(of: $0) }
            await connections.closeAll()
            try run.get()
            Attachment.record(
                results.joined(separator: "\n") + "\npointer put back \(pointer == true ? 1 : 0)",
                named: "live-monitors-gone.txt")
            #expect(results.first?.hasPrefix("mirror ended 1") == true)
            #expect(results.last == "a new mirror finds it missing 1")
            #expect(pointer == true)
        }

        private func listed() async throws -> [RemoteScreen] {
            try await ScreenLister(connections: connections, target: target).screens()
        }

        private func mirror(of screen: RemoteScreen) -> LiveFocusScreen {
            LiveFocusScreen(
                connections: connections, target: target, screen: .named(screen.name),
                largest: (UInt32(screen.width), UInt32(screen.height)))
        }

        private func nap(_ seconds: Double) async throws { try await Task.sleep(for: .seconds(seconds)) }

        private static let offer = LocalClipboardOffer(
            mimeTypes: ClipboardMimes.forwardable([ClipboardMimes.text]), token: 1, isPassword: false)

        /// Whether the host's clipboard reads as `marker` within 10 s.
        private static func paste(until marker: String) async throws -> Bool {
            let target = try #require(LiveHost.target)
            for _ in 0..<10 {
                let paste = try await LiveRemote.run(target, LiveRemote.paste)
                if paste.status == 0, paste.output == marker { return true }
                try await Task.sleep(for: .seconds(1))
            }
            return false
        }
    }

    /// The host's pointer and focused monitor before a check, and the nudge that puts them back.
    private struct PutBack {
        let cursor: (x: Double, y: Double)
        let focused: LiveHyprland.Monitor

        static func record() throws -> PutBack {
            let id = try #require(try LiveHyprland.focusedMonitor())
            let focused = try #require(try LiveHyprland.monitors().first { $0.id == id })
            return PutBack(cursor: try LiveHyprland.cursor(), focused: focused)
        }

        /// Whether the pointer and focus are back, after a nudge through the mirror of the
        /// monitor that had focus (among `mirrors`, of `screens`; else one `open` makes for a
        /// few seconds) when they moved.
        func restore(
            through mirrors: [LiveFocusScreen], screens: [RemoteScreen],
            open: ((RemoteScreen) -> LiveFocusScreen)? = nil
        ) async throws -> Bool {
            if try isBack() { return true }
            let screen = try #require(screens.first { $0.name == focused.name })
            var opened: LiveFocusScreen?
            let mirror: LiveFocusScreen
            if let index = screens.firstIndex(of: screen), index < mirrors.count {
                mirror = mirrors[index]
            } else {
                let made = try #require(open?(screen))
                opened = made
                mirror = made
            }
            let done: Result<Bool, any Error> = await caught {
                _ = try await mirror.streaming()
                try mirror.activate(macPointer: (cursor.x - focused.x, cursor.y - focused.y))
                try await Task.sleep(for: .seconds(1))
                mirror.capture(.windowKey(false))
                return try isBack()
            }
            await opened?.end()
            return try done.get()
        }

        private func isBack() throws -> Bool {
            let now = try LiveHyprland.cursor()
            let focusedNow = try LiveHyprland.focusedMonitor()
            return abs(now.x - cursor.x) <= 1 && abs(now.y - cursor.y) <= 1 && focusedNow == focused.id
        }
    }

    /// `body`'s outcome, so a check's cleanup runs before its error is thrown.
    private func caught<T>(_ body: () async throws -> T) async -> Result<T, any Error> {
        do { return .success(try await body()) } catch { return .failure(error) }
    }

    /// A clipboard source that serves `text` for any type and counts the host's reads.
    private final class ReadCounter: LocalClipboardSource {
        private let text: [UInt8]
        private let count = Mutex(0)

        init(_ text: [UInt8]) { self.text = text }

        var reads: Int { count.withLock { $0 } }

        func source(for mime: String, token: Int) async throws(TransferError) -> any ChunkSource {
            count.withLock { $0 += 1 }
            return MemorySource(text)
        }
    }
#endif
