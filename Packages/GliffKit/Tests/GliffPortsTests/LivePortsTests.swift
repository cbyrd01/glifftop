#if os(macOS)
    import Foundation
    import GliffTransport
    import Testing

    @testable import GliffPorts

    /// The host's ports against a real host, through the Mac's own OpenSSH. Off unless
    /// `GLIFFTOP_LIVE_HOST` names an ssh destination. It writes only a directory under the
    /// host's `$XDG_RUNTIME_DIR`, removed at the end, and runs a web server there on 127.0.0.1
    /// for at most 60 s, ended with its channel.
    @Suite(
        .serialized,
        .enabled(
            if: ProcessInfo.processInfo.environment["GLIFFTOP_LIVE_HOST"] != nil,
            "set GLIFFTOP_LIVE_HOST to run against a real host"))
    struct LivePortsTests {
        /// A tab's lease on the host and a window's hold on its ports.
        struct Window {
            let host: LivePortsHost
            let tab: HostLease
            let hold: PortsHold
            let ports: HostPorts
        }

        /// A server started after the first frame is offered, named, within two frames.
        @Test func theWatcherSeesANewServerWithinFourSeconds() async throws {
            try await withWindow { window in
                let ports = window.ports
                #expect(await eventually(10) { await ports.frame != nil })
                let (server, port) = try await window.host.startServer(on: window.tab)
                #expect(await eventually(4) { await Self.offers(port, ports) })
                #expect(await Self.listed(port, ports)?.name?.hasPrefix("python3") == true)
                await server.close()
            }
        }

        @Test func aForwardServesAPage() async throws {
            try await withWindow { window in
                let ports = window.ports
                let (server, port) = try await window.host.startServer(on: window.tab)
                await ports.forward(remote: port, destination: .localhost, localPort: nil)
                let local = try #require(await Self.active(port, ports))
                let page = await LivePortsHost.page(try #require(URL(string: "http://localhost:\(local)/")))
                #expect(page == window.host.marker)
                await server.close()
            }
        }

        /// The connection dies: the forward waits, and comes back on the same Mac port once a
        /// tab connects again.
        @Test func aForwardComesBackAfterTheConnectionDies() async throws {
            try await withWindow { window in
                let ports = window.ports
                let port = Int.random(in: 20000...29999)
                await ports.forward(remote: port, destination: .localhost, localPort: nil)
                let local = try #require(await Self.active(port, ports))
                await window.host.latest?.invalidate()
                #expect(await eventually(10) { await Self.state(port, ports) == .waiting })
                let again = try await window.host.connections.lease(for: window.host.target)
                #expect(
                    await eventually(20) {
                        if case .active(local, _) = await Self.state(port, ports) { true } else { false }
                    })
                await again.end()
            }
        }

        /// Once the ports' grace and the connection's have run out, no watcher shell is left.
        @Test func noWatcherShellIsLeft() async throws {
            try await withWindow { window in
                let host = window.host
                #expect(await eventually(10) { await window.ports.detection == .running })
                let nonces = host.nonces
                try #require(!nonces.isEmpty)
                let connection = try #require(host.latest)
                await window.hold.end()
                await window.tab.end()
                #expect(await eventually(20) { await host.registry.ports(for: host.target) == nil })
                _ = await connection.ended()
                let check = try await host.connections.lease(for: host.target)
                let pattern = "gliff-port[s] (\(nonces.joined(separator: "|")))"
                let left = try await LivePortsHost.run(
                    "pgrep -f \(SSHCommand.shellQuoted(pattern)) >/dev/null && echo left || echo none",
                    on: check)
                #expect(left == "none\n")
                await check.end()
            }
        }

        /// Runs `body` with a window on the host, then ends it (once more is nothing) and cleans
        /// the host up, whatever `body` throws.
        private func withWindow(_ body: (Window) async throws -> Void) async throws {
            guard let host = try await LivePortsHost.open() else {
                try Test.cancel("the host has no XDG_RUNTIME_DIR or no python3")
            }
            do {
                let tab = try await host.connections.lease(for: host.target)
                let hold = await host.registry.hold(host.target, saved: [])
                let ports = try #require(await host.registry.ports(for: host.target))
                try await body(Window(host: host, tab: tab, hold: hold, ports: ports))
                await hold.end()
                await tab.end()
            } catch {
                await host.close()
                throw error
            }
            await host.close()
        }

        private static func listed(_ port: Int, _ ports: HostPorts) async -> RemotePort? {
            let snapshot = await ports.snapshot
            return (snapshot.available + snapshot.other).first { $0.port == port }
        }

        /// Whether a notice offers `port`: the first frame never does.
        private static func offers(_ port: Int, _ ports: HostPorts) async -> Bool {
            await ports.snapshot.notices.contains {
                switch $0 {
                case .listening(let offered, _): offered == port
                case .several(let offered): offered.contains(port)
                case .forwarded, .moved: false
                }
            }
        }

        private static func state(_ port: Int, _ ports: HostPorts) async -> ForwardState? {
            await ports.snapshot.forwarded.first { $0.remotePort == port }?.state
        }

        /// The Mac port of the forward of `port`, once active.
        private static func active(_ port: Int, _ ports: HostPorts) async -> Int? {
            var local: Int?
            _ = await eventually(10) {
                if case .active(let mac, _) = await state(port, ports) { local = mac }
                return local != nil
            }
            return local
        }
    }
#endif
