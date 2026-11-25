#if os(macOS)
    import Foundation
    import Testing

    @testable import GliffTransport

    /// Forward and cancel on a `SystemSSHConnection`, against `SystemSSHConnectionTests`' stub
    /// ssh, which logs each `-O forward` and `-O cancel` as it starts (`+`) and ends (`-`).
    @Suite final class SystemSSHConnectionForwardsTests {
        let root = URL(filePath: "/tmp/ssf-\(UUID().uuidString.prefix(8))")
        var socket: String { root.path + "/1-1" }

        init() throws {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        func open(_ environment: String = "", config: SSHResolvedConfig? = SSHResolvedConfig(resolved: ""))
            async throws -> SystemSSHConnection
        {
            try await SystemSSHConnection.open(
                target: try SSHTarget("omarchy"), socket: socket, config: config, questions: nil, helper: nil,
                executable: SystemSSHConnectionTests.install(in: root, environment))
        }

        var requests: [String] {
            ((try? String(contentsOf: root.appending(path: "requests"), encoding: .utf8)) ?? "")
                .split(separator: "\n").map(String.init)
        }

        static let web = PortForward(localPort: 5173, destination: .localhost, remotePort: 5173)!
        static let api = PortForward(
            localPort: 8080, destination: .address(IPLiteral("2001:db8::1")!), remotePort: 80)!

        @Test func aForwardAsksTheMasterOnEachLoopback() async throws {
            let connection = try await open()
            try await connection.forward(Self.web, on: .ipv4)
            try await connection.forward(Self.api, on: .ipv6)
            try await connection.cancel(Self.web, on: .ipv4)
            #expect(
                requests == [
                    "+forward 127.0.0.1:5173:localhost:5173", "-forward 127.0.0.1:5173:localhost:5173",
                    "+forward [::1]:8080:[2001:db8::1]:80", "-forward [::1]:8080:[2001:db8::1]:80",
                    "+cancel 127.0.0.1:5173:localhost:5173", "-cancel 127.0.0.1:5173:localhost:5173",
                ])
            await connection.close()
        }

        @Test func aBusyPortIsLocalPortInUse() async throws {
            let connection = try await open(
                "STUB_FORWARD_STATUS=255; STUB_FORWARD_ERROR='mux_client_forward: forwarding request failed: Port forwarding failed'"
            )
            await #expect(throws: ForwardError.localPortInUse) {
                try await connection.forward(Self.web, on: .ipv4)
            }
            await connection.close()
        }

        @Test func aCancelOfAnAbsentForwardIsFine() async throws {
            let connection = try await open("STUB_FORWARD_ERROR='mux_client_forward: port not forwarded'")
            try await connection.cancel(Self.web, on: .ipv6)
            await connection.close()
        }

        /// Two forwards asked at once reach the master one after the other.
        @Test func requestsRunOneAtATime() async throws {
            let connection = try await open("STUB_FORWARD_DELAY=0.15")
            async let first: Void = connection.forward(Self.web, on: .ipv4)
            async let second: Void = connection.forward(Self.api, on: .ipv4)
            _ = try await (first, second)
            let log = requests
            #expect(log.count == 4)
            #expect(
                log[0].hasPrefix("+") && log[1].hasPrefix("-") && log[2].hasPrefix("+")
                    && log[3].hasPrefix("-"))
            #expect(log[0].dropFirst() == log[1].dropFirst())
            await connection.close()
        }

        /// A caller cancelled while its request runs still gets the master's real answer: the
        /// request isn't cut short, which could leave a listener nobody knows of.
        @Test func aCancelledCallerLetsItsRequestFinish() async throws {
            let connection = try await open("STUB_FORWARD_DELAY=0.3")
            let asked = Task { try await connection.forward(Self.web, on: .ipv4) }
            #expect(await eventually { self.requests.contains { $0.hasPrefix("+forward") } })
            asked.cancel()
            try await asked.value
            #expect(requests.last == "-forward 127.0.0.1:5173:localhost:5173")
            await connection.close()
        }

        /// A config forward is asked with the same text `configuredForwards` gives it, so a
        /// later cancel of that forward matches it.
        @Test func aConfigForwardIsAskedAsItIsReported() async throws {
            let config = SSHResolvedConfig(resolved: "localforward 8080 [2001:DB8:0::1]:80\n")
            let connection = try await open(config: config)
            let reported = try #require(await connection.configuredForwards.local.first?.forward)
            #expect(SSHForwardSpec.make(reported, on: .ipv4) == "127.0.0.1:8080:[2001:db8::1]:80")
            #expect(await eventually { self.requests.contains("-forward 127.0.0.1:8080:[2001:db8::1]:80") })
            await connection.close()
        }

        @Test func afterTheMasterEndsAForwardIsConnectionLost() async throws {
            let connection = try await open()
            await connection.close()
            await #expect(throws: ForwardError.connectionLost) {
                try await connection.forward(Self.web, on: .ipv4)
            }
            await #expect(throws: ForwardError.connectionLost) {
                try await connection.cancel(Self.web, on: .ipv4)
            }
        }

        /// A request the master drops as it ends is the connection lost, whatever ssh said: even
        /// when ssh answers while the master is still ending, and while a child of the master
        /// holds its pipes.
        @Test(arguments: ["forward", "cancel"])
        func aRequestCutShortByTheMastersEndIsConnectionLost(_ request: String) async throws {
            let connection = try await open(
                "STUB_HOLD_PIPES=1; STUB_DYING=0.5; STUB_FORWARD_DELAY=0.3; STUB_FORWARD_STATUS=255; STUB_FORWARD_ERROR='read from master failed: Broken pipe'"
            )
            let asked = Task {
                if request == "forward" {
                    try await connection.forward(Self.web, on: .ipv4)
                } else {
                    try await connection.cancel(Self.web, on: .ipv4)
                }
            }
            #expect(await eventually { self.requests.contains { $0.hasPrefix("+\(request)") } })
            kill(try #require(SystemSSHConnectionTests.writtenMasterPID(in: root)), SIGTERM)
            await #expect(throws: ForwardError.connectionLost) { try await asked.value }
            await connection.close()
        }

        /// Two config lines that differ only in their bind are one forward, listed once.
        @Test func aConfigForwardIsListedOnce() async throws {
            let config = SSHResolvedConfig(
                resolved: """
                    localforward 8080 [db]:80
                    localforward [127.0.0.1]:8080 [db]:80

                    """)
            let connection = try await open(config: config)
            let local = await connection.configuredForwards.local
            #expect(local.count == 1)
            #expect(local.first?.bind == nil)
            await connection.close()
        }

        /// The config's forwards come from the probe the open read: under 1024 and other kinds
        /// are lines not applied, and a bind address is kept for display.
        @Test func theConfigsForwardsComeFromTheProbe() async throws {
            let config = SSHResolvedConfig(
                resolved: """
                    localforward [*]:5432 [db]:5432
                    localforward 80 [localhost]:80
                    remoteforward 9000 [localhost]:9000

                    """)
            let connection = try await open(config: config)
            let configured = await connection.configuredForwards
            let db = try #require(ForwardDestination(configuredHost: "db"))
            let forward = try #require(PortForward(localPort: 5432, destination: db, remotePort: 5432))
            #expect(configured.local == [ConfiguredForward(forward: forward, bind: "*")])
            #expect(
                configured.notApplied == [
                    "localforward 80 [localhost]:80", "remoteforward 9000 [localhost]:9000",
                ])
            await connection.close()
        }
    }
#endif
