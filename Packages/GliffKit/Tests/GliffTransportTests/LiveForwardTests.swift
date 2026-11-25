#if os(macOS)
    import Foundation
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
        /// leaves the master up and is skipped; a second, free one is forwarded on 127.0.0.1
        /// only, its config's `localhost` bind not used, and carries a TCP connection.
        @Test func aBusyForwardIsSkippedAndAFreeOneCarriesAConnection() async throws {
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
                command: command, executable: URL(filePath: SSHCommand.executable))
            do {
                // A channel opening while the busy port is held, before and after the forwards.
                #expect(try await Self.echo(on: connection))
                #expect(await connection.addForwards(config.localForwards) == 1)
                #expect(try await Self.echo(on: connection))
                #expect(Self.firstBytes(host: "127.0.0.1", port: free)?.hasPrefix("SSH-2.0-") == true)
                #expect(Self.firstBytes(host: "::1", port: free) == nil)
            } catch {
                await connection.close()
                throw error
            }
            await connection.close()
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
