#if os(macOS)
    import Foundation
    import Testing

    @testable import GliffTransport

    /// `SystemSSHConnection` against a real host, through the Mac's own OpenSSH. Off unless
    /// `GLIFFTOP_LIVE_HOST` names an ssh destination; it runs only `hostname` and `echo` there.
    @Suite(
        .serialized,
        .enabled(
            if: ProcessInfo.processInfo.environment["GLIFFTOP_LIVE_HOST"] != nil,
            "set GLIFFTOP_LIVE_HOST to run against a real host"))
    final class LiveHostConnectionTests {
        let root = URL(filePath: "/tmp/lhc-\(UUID().uuidString.prefix(8))")
        var socket: String { root.path + "/1-1" }

        init() throws {
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        func target() throws -> SSHTarget {
            try SSHTarget(ProcessInfo.processInfo.environment["GLIFFTOP_LIVE_HOST"] ?? "")
        }

        /// The ssh processes that are masters on this test's socket.
        func masters() throws -> Int {
            let ps = Process()
            ps.executableURL = URL(filePath: "/bin/ps")
            ps.arguments = ["-axww", "-o", "args="]
            let out = Pipe()
            ps.standardOutput = out
            try ps.run()
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            ps.waitUntilExit()
            return text.split(separator: "\n").count {
                $0.contains(socket) && $0.contains("ControlMaster=yes")
            }
        }

        static func output(of channel: any ByteConnection) async throws -> String {
            var bytes: [UInt8] = []
            for try await chunk in channel.incoming { bytes += chunk }
            return String(decoding: bytes, as: UTF8.self)
        }

        @Test func twoChannelsOneMaster() async throws {
            let connection = try await SystemSSHConnection.open(target: target(), socket: socket)
            let channels = [
                try await connection.channel(command: "hostname >/dev/null; echo ok"),
                try await connection.channel(command: "hostname >/dev/null; echo ok"),
            ]
            async let first = Self.output(of: channels[0])
            async let second = Self.output(of: channels[1])
            #expect(try await [first, second] == ["ok\n", "ok\n"])
            #expect(try masters() == 1)
            await connection.close()
            #expect(try masters() == 0)
            #expect(!FileManager.default.fileExists(atPath: socket))
        }

        /// Without its master a channel can't sign in on its own (`ProxyCommand=/usr/bin/false`).
        @Test func aChannelWithoutItsMasterFailsAtOnce() async throws {
            let command = try SSHMasterCommand(target: target(), socket: socket)
            let connection = try await SystemSSHConnection.open(target: target(), socket: socket)
            await connection.invalidate()
            let started = ContinuousClock.now
            let channel = try ProcessConnection.launch(
                executable: URL(filePath: SSHCommand.executable), arguments: command.channel("echo ok"),
                classify: SSHErrorClassifier.classifyChannel)
            await #expect(throws: TransportError.exited(status: 255, failure: .sharedConnectionLost)) {
                _ = try await Self.output(of: channel)
            }
            #expect(ContinuousClock.now - started < .seconds(2))
        }
    }
#endif
