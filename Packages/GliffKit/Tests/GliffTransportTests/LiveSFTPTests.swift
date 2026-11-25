#if os(macOS)
    import Foundation
    import Testing

    @testable import GliffTransport

    /// The sftp subsystem through a real master, against the system's sshd on loopback. Off
    /// unless `GLIFFTOP_LIVE_SSHD=1`.
    @Suite(
        .serialized,
        .enabled(
            if: ProcessInfo.processInfo.environment["GLIFFTOP_LIVE_SSHD"] == "1",
            "set GLIFFTOP_LIVE_SSHD=1 to run against a loopback sshd"))
    struct LiveSFTPTests {
        /// INIT (version 3) over the subsystem channel is answered with VERSION 3, which lists
        /// `posix-rename@openssh.com`.
        @Test func theSFTPSubsystemAnswersVersionThree() async throws {
            let sshd = try LoopbackSSHD()
            defer { sshd.stop() }
            try sshd.trustHostKey()
            let arguments = try ["-F", sshd.config(identity: "id")]
            let command = try SSHMasterCommand(
                target: SSHTarget(LoopbackSSHD.alias), socket: sshd.directory.appending(path: "m").path,
                sshArguments: arguments)
            let connection = try await SystemSSHConnection.open(
                command: command, executable: URL(filePath: SSHCommand.executable))
            do {
                let channel = try await connection.channel(subsystem: "sftp")
                try await channel.write([0, 0, 0, 5, 1, 0, 0, 0, 3])
                // A server that never answers is cut off after 10 s.
                let timer = Task {
                    try await Task.sleep(for: .seconds(10))
                    await channel.close()
                }
                var reply: [UInt8] = []
                for try await chunk in channel.incoming {
                    reply += chunk
                    if reply.count >= 4, reply.count >= 4 + Self.length(reply) { break }
                }
                timer.cancel()
                await channel.close()
                try #require(reply.count > 9)
                #expect(Array(reply[4..<9]) == [2, 0, 0, 0, 3])
                let text = String(decoding: reply, as: UTF8.self)
                #expect(text.contains("posix-rename@openssh.com"))
            } catch {
                await connection.close()
                throw error
            }
            await connection.close()
        }

        static func length(_ bytes: [UInt8]) -> Int {
            bytes.prefix(4).reduce(0) { $0 << 8 | Int($1) }
        }
    }
#endif
