#if os(macOS)
    import Foundation
    import GliffPorts
    import GliffTestSupport
    import Testing

    @testable import GliffTransport

    /// The config's port forwards against the system's sshd on loopback, through the real ssh.
    /// Off unless `GLIFFTOP_LIVE_SSHD=1`.
    @Suite(
        .serialized,
        .enabled(
            if: ProcessInfo.processInfo.environment["GLIFFTOP_LIVE_SSHD"] == "1",
            "set GLIFFTOP_LIVE_SSHD=1 to run against a loopback sshd"))
    struct LiveForwardTests {
        /// A `LocalForward` on a port another program holds, under `ExitOnForwardFailure yes`,
        /// leaves the master up and fails as in use; a second, free one is forwarded by the
        /// host's ports on both loopbacks, its config's `localhost` bind not used, and carries a
        /// TCP connection on each.
        @Test func aBusyForwardFailsAndAFreeOneCarriesAConnection() async throws {
            let sshd = try LoopbackSSHD()
            defer { sshd.stop() }
            try sshd.trustHostKey()
            let busy = try HeldPort()
            defer { busy.close() }
            let free = try LoopbackSSHD.freePort()
            let arguments = try [
                "-F",
                sshd.config(
                    identity: "id",
                    extra: [
                        "ExitOnForwardFailure yes",
                        "LocalForward 127.0.0.1:\(busy.port) 127.0.0.1:\(sshd.port)",
                        "LocalForward localhost:\(free) 127.0.0.1:\(sshd.port)",
                    ]),
            ]
            let target = try SSHTarget(LoopbackSSHD.alias)
            let config = try #require(await SSHResolvedConfig.probe(sshArguments: arguments, target: target))
            #expect(config.localForwards.count == 2)
            let command = SSHMasterCommand(
                target: target, socket: sshd.directory.appending(path: "m").path, sshArguments: arguments)
            let connection = try await SystemSSHConnection.open(
                command: command, executable: URL(filePath: SSHCommand.executable),
                configured: ConfiguredForwards(config: config))
            // The grace never runs out: the test ends the master itself.
            let connections = HostConnections(open: { _, _ in connection }, clock: ManualClock())
            let registry = PortsRegistry(connections: connections, clock: ManualClock())
            var tab: HostLease?
            var hold: PortsHold?
            var failure: (any Error)?
            do {
                // A channel opening while the busy port is held, before and after the forwards.
                #expect(try await Self.echo(on: connection))
                tab = try await connections.lease(for: target)
                hold = await registry.hold(target, saved: [])
                let ports = try #require(await registry.ports(for: target))
                let wanted: [ForwardState] = [
                    .failed(.localPortInUse), .active(local: free, loopbacks: .both),
                ]
                #expect(
                    await eventually(within: .seconds(10)) {
                        await ports.snapshot.forwarded.map(\.state) == wanted
                    })
                #expect(try await Self.echo(on: connection))
                #expect(Self.firstBytes(host: "127.0.0.1", port: free)?.hasPrefix("SSH-2.0-") == true)
                #expect(Self.firstBytes(host: "::1", port: free)?.hasPrefix("SSH-2.0-") == true)
            } catch {
                failure = error
            }
            await hold?.end()
            await tab?.end()
            await connection.close()
            if let failure { throw failure }
        }

        /// A forward asked on each loopback binds both through the mux, and each carries a TCP
        /// connection to the host; cancelling both frees the port.
        @Test func aForwardCarriesAConnectionOnBothLoopbacks() async throws {
            let sshd = try LoopbackSSHD()
            defer { sshd.stop() }
            let (connection, _) = try await Self.open(sshd)
            let free = try LoopbackSSHD.freePort()
            let destination = ForwardDestination.address(try #require(IPLiteral("127.0.0.1")))
            let forward = try #require(
                PortForward(localPort: free, destination: destination, remotePort: sshd.port))
            do {
                try await connection.forward(forward, on: .ipv4)
                try await connection.forward(forward, on: .ipv6)
                #expect(Self.firstBytes(host: "127.0.0.1", port: free)?.hasPrefix("SSH-2.0-") == true)
                #expect(Self.firstBytes(host: "::1", port: free)?.hasPrefix("SSH-2.0-") == true)
                #expect(LoopbackPorts.check(free) == .taken)
                // The same forward again is the master's own: it answers success.
                try await connection.forward(forward, on: .ipv4)
                let other = try #require(
                    PortForward(localPort: free, destination: destination, remotePort: sshd.port + 1))
                await #expect(throws: ForwardError.localPortInUse) {
                    try await connection.forward(other, on: .ipv4)
                }
                try await connection.cancel(forward, on: .ipv4)
                try await connection.cancel(forward, on: .ipv6)
                // One cancelled already, and one the master never held, are both gone.
                try await connection.cancel(forward, on: .ipv6)
                try await connection.cancel(other, on: .ipv6)
                #expect(LoopbackPorts.check(free) == .free)
            } catch {
                await connection.close()
                throw error
            }
            await connection.close()
        }

        /// ssh's own answers once the master is gone: both classified as the connection lost.
        @Test func cancelAfterTheMasterStoppedIsConnectionLost() async throws {
            let sshd = try LoopbackSSHD()
            defer { sshd.stop() }
            let (connection, command) = try await Self.open(sshd)
            await connection.close()
            let forward = try #require(PortForward(localPort: 40000, destination: .localhost, remotePort: 22))
            let spec = SSHForwardSpec.make(forward, on: .ipv4)
            let executable = URL(filePath: SSHCommand.executable)
            let cancel = try await ProcessOutput.exit(
                executable: executable, arguments: command.cancel(spec), timeout: .seconds(5)
            ).get()
            #expect(cancel.status == 255)
            #expect(throws: ForwardError.connectionLost) {
                try SSHForwardClassifier.cancel(status: cancel.status, stderr: cancel.stderr).get()
            }
            let add = try await ProcessOutput.exit(
                executable: executable, arguments: command.forward(spec), timeout: .seconds(5)
            ).get()
            #expect(throws: ForwardError.connectionLost) {
                try SSHForwardClassifier.forward(status: add.status, stderr: add.stderr).get()
            }
            await #expect(throws: ForwardError.connectionLost) {
                try await connection.cancel(forward, on: .ipv4)
            }
        }

        /// A config that forwards the agent, runs a remote command and asks for a terminal still
        /// gives a channel that runs Glifftop's command.
        @Test func aConfigWithForwardAgentAndRemoteCommandStillOpensAChannel() async throws {
            let sshd = try LoopbackSSHD()
            defer { sshd.stop() }
            let (connection, _) = try await Self.open(
                sshd,
                extra: [
                    "ForwardAgent yes", "RemoteCommand echo other", "RequestTTY yes", "StdinNull yes",
                    "ForkAfterAuthentication yes", "SessionType subsystem",
                ])
            let ran = try await Self.echo(on: connection)
            let channel = try await connection.channel(command: "head -c 3")
            try await channel.write(Array("abc".utf8))
            let read = await ProcessOutput.read(channel, maxBytes: 64, timeout: .seconds(10))
            await connection.close()
            #expect(ran)
            #expect(read == .success(Array("abc".utf8)))
        }

        /// A master on `sshd`, its config with `extra` lines.
        static func open(_ sshd: LoopbackSSHD, extra: [String] = []) async throws
            -> (SystemSSHConnection, SSHMasterCommand)
        {
            try sshd.trustHostKey()
            let arguments = try ["-F", sshd.config(identity: "id", extra: extra)]
            let command = SSHMasterCommand(
                target: try SSHTarget(LoopbackSSHD.alias), socket: sshd.directory.appending(path: "m").path,
                sshArguments: arguments)
            let connection = try await SystemSSHConnection.open(
                command: command, executable: URL(filePath: SSHCommand.executable))
            return (connection, command)
        }

        /// Whether a channel on `connection` runs a command.
        static func echo(on connection: SystemSSHConnection) async throws -> Bool {
            let channel = try await connection.channel(command: "echo ok")
            let output = await ProcessOutput.read(channel, maxBytes: 64, timeout: .seconds(10))
            return output == .success(Array("ok\n".utf8))
        }

        /// What a TCP connection to `host` (a numeric address) and `port` first reads, within
        /// 5 s; nil when it can't connect or reads nothing.
        static func firstBytes(host: String, port: Int) -> String? {
            var hints = addrinfo()
            hints.ai_flags = AI_NUMERICHOST
            hints.ai_socktype = SOCK_STREAM
            var found: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, String(port), &hints, &found) == 0, let info = found else { return nil }
            defer { freeaddrinfo(found) }
            let socket = Darwin.socket(info.pointee.ai_family, SOCK_STREAM, 0)
            guard socket >= 0 else { return nil }
            defer { close(socket) }
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            guard connect(socket, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 else { return nil }
            var buffer = [UInt8](repeating: 0, count: 64)
            let count = recv(socket, &buffer, buffer.count, 0)
            return count > 0 ? String(decoding: buffer.prefix(count), as: UTF8.self) : nil
        }
    }
#endif
