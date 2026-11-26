#if os(macOS)
    import Foundation
    import GliffPorts
    import Synchronization
    import Testing

    @testable import GliffTransport

    /// The live check's host (`GLIFFTOP_LIVE_HOST`): its connections, the app's own ssh
    /// masters with their channels' commands kept (the watcher's nonce is in them), and its
    /// scratch directory, made by `mktemp -d` under `$XDG_RUNTIME_DIR` and removed by that
    /// exact path.
    final class LivePortsHost: Sendable {
        let target: SSHTarget
        let connections: HostConnections
        let registry: PortsRegistry
        /// The directory on the host: its `index.html` holds `marker`.
        let directory: String
        let marker: String
        private let log: CommandLog

        /// Nil (and nothing left on the host) when the host has no `$XDG_RUNTIME_DIR` or no
        /// `python3`.
        static func open() async throws -> LivePortsHost? {
            let target = try SSHTarget(ProcessInfo.processInfo.environment["GLIFFTOP_LIVE_HOST"] ?? "")
            let log = CommandLog()
            let open = SystemSSH.opener()
            let connections = HostConnections(
                open: { target, asker throws(TransportError) in
                    RecordingConnection(try await open(target, asker), log: log)
                }, grace: .seconds(1))
            let marker = "glifftop-live-\(UUID().uuidString.prefix(8))"
            let output: String
            do {
                output = try await once(
                    """
                    [ -n "$XDG_RUNTIME_DIR" ] && command -v python3 >/dev/null || exit 0
                    d=$(mktemp -d "$XDG_RUNTIME_DIR/glifftop-live-XXXXXX") || exit 1
                    printf %s \(marker) > "$d/index.html" && printf '%s\\n' "$d"
                    """, target, connections)
            } catch {
                await connections.closeAll()
                throw error
            }
            let made = output.split(separator: "\n").last.map(String.init) ?? ""
            guard made.hasPrefix("/"), made.contains("/glifftop-live-") else {
                await connections.closeAll()
                return nil
            }
            return LivePortsHost(
                target: target, connections: connections, directory: made, marker: marker, log: log)
        }

        private init(
            target: SSHTarget, connections: HostConnections, directory: String, marker: String,
            log: CommandLog
        ) {
            self.target = target
            self.connections = connections
            self.directory = directory
            self.marker = marker
            self.log = log
            registry = PortsRegistry(connections: connections)
        }

        /// Removes the directory on the host by its path, then ends every connection.
        func close() async {
            _ = try? await Self.once("rm -rf -- \(SSHCommand.shellQuoted(directory))", target, connections)
            await connections.closeAll()
        }

        /// The watcher's nonces, from the commands run so far.
        var nonces: [String] {
            log.commands.compactMap { command in
                guard let range = command.range(of: "gliff-ports ") else { return nil }
                return String(command[range.upperBound...].prefix { $0.isHexDigit })
            }
        }

        /// The connection opened last.
        var latest: (any HostConnection)? { log.latest }

        /// A web server on the host, on a port from 20000–29999 (another if that one is
        /// taken), serving `directory` on 127.0.0.1 for at most 60 s; closing its channel ends it.
        func startServer(on tab: HostLease) async throws -> (channel: any ByteConnection, port: Int) {
            for _ in 0..<5 {
                let port = Int.random(in: 20000...29999)
                let script = """
                    exec 3<&0; { cat <&3 >/dev/null; kill 0; } & exec 0</dev/null 3<&-; \
                    timeout --foreground 60 python3 -u -m http.server --bind 127.0.0.1 \
                    --directory \(SSHCommand.shellQuoted(directory)) \(port)
                    """
                let channel = try await tab.channel(command: Self.sh(script))
                if await Self.announces(channel) { return (channel, port) }
                await channel.close()
            }
            throw NoServer()
        }

        /// Whether the server says it is serving before its output ends.
        private static func announces(_ channel: any ByteConnection) async -> Bool {
            var text = ""
            do {
                for try await chunk in channel.incoming {
                    text += String(decoding: chunk, as: UTF8.self)
                    if text.contains("Serving HTTP") { return true }
                }
            } catch {}
            return false
        }

        /// `script` under `sh`, whatever the login shell is.
        static func sh(_ script: String) -> String { "sh -c \(SSHCommand.shellQuoted(script))" }

        /// One `sh` script's output on a channel of `tab`'s connection, within 10 s.
        static func run(_ script: String, on tab: HostLease) async throws -> String {
            let output = await ProcessOutput.read(
                try await tab.channel(command: sh(script)), maxBytes: 4096, timeout: .seconds(10))
            return String(decoding: try output.get(), as: UTF8.self)
        }

        /// One command's output on a lease of its own.
        private static func once(_ command: String, _ target: SSHTarget, _ connections: HostConnections)
            async throws -> String
        {
            let tab = try await connections.lease(for: target)
            do {
                let output = try await run(command, on: tab)
                await tab.end()
                return output
            } catch {
                await tab.end()
                throw error
            }
        }

        /// The page at `url`, if one answers.
        static func page(_ url: URL) async -> String? {
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                (response as? HTTPURLResponse)?.statusCode == 200
            else { return nil }
            return String(decoding: data, as: UTF8.self)
        }
    }

    /// No port in five tries let the server bind.
    struct NoServer: Error {}

    /// The commands every connection ran, and the connection opened last.
    final class CommandLog: Sendable {
        private let state = Mutex<(commands: [String], latest: (any HostConnection)?)>(([], nil))

        var commands: [String] { state.withLock { $0.commands } }
        var latest: (any HostConnection)? { state.withLock { $0.latest } }

        func ran(_ command: String) { state.withLock { $0.commands.append(command) } }
        func opened(_ connection: any HostConnection) { state.withLock { $0.latest = connection } }
    }

    /// A connection whose channels' commands go to a log.
    final class RecordingConnection: HostConnection {
        private let base: any HostConnection
        private let log: CommandLog

        init(_ base: any HostConnection, log: CommandLog) {
            (self.base, self.log) = (base, log)
            log.opened(base)
        }

        func channel(command: String) async throws(TransportError) -> any ByteConnection {
            log.ran(command)
            return try await base.channel(command: command)
        }

        func ended() async -> ConnectFailure? { await base.ended() }
        func invalidate() async { await base.invalidate() }
        func close() async { await base.close() }

        func forward(_ forward: PortForward, on loopback: Loopback) async throws(ForwardError) {
            try await base.forward(forward, on: loopback)
        }

        func cancel(_ forward: PortForward, on loopback: Loopback) async throws(ForwardError) {
            try await base.cancel(forward, on: loopback)
        }

        var configuredForwards: ConfiguredForwards { get async { await base.configuredForwards } }
    }
#endif
