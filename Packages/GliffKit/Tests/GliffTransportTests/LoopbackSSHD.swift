#if os(macOS)
    import Foundation

    /// The system's sshd, run as this user on a free 127.0.0.1 port, in a directory of its own
    /// with its own host key, `authorized_keys`, `known_hosts` and `ssh_config`: a host to sign
    /// in to without touching the person's ssh files. Signing in is by key only; a user-run sshd
    /// has no PAM, so it can't check a password.
    final class LoopbackSSHD: Sendable {
        /// The `Host` the config names.
        static let alias = "glifftop-loopback"
        /// The encrypted key's passphrase.
        static let passphrase = "spike-pass"

        let directory: URL
        let port: Int
        private let process: Process
        /// Signalled as sshd exits: `waitUntilExit` hears of the exit only through the run loop
        /// of the thread that started it, which a concurrency thread doesn't run.
        private let exited = DispatchSemaphore(value: 0)

        /// Starts sshd with `banner` shown before sign-in, and waits until it listens.
        init(banner: String? = nil) throws {
            let base = URL(filePath: NSTemporaryDirectory()).appending(
                path: "gl-\(UUID().uuidString.prefix(8))")
            try FileManager.default.createDirectory(
                at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            directory = base
            for (name, passphrase) in [("host_key", ""), ("id", ""), ("id_enc", Self.passphrase)] {
                try Self.run(
                    "/usr/bin/ssh-keygen",
                    [
                        "-q", "-t", "ed25519", "-N", passphrase, "-C", "loopback", "-f",
                        base.appending(path: name).path,
                    ])
            }
            let keys = try ["id.pub", "id_enc.pub"].map {
                try String(contentsOf: base.appending(path: $0), encoding: .utf8)
            }
            try Self.write(keys.joined(), to: base.appending(path: "authorized_keys"))
            port = try Self.freePort()
            var config = """
                ListenAddress 127.0.0.1:\(port)
                HostKey \(base.appending(path: "host_key").path)
                PidFile none
                UsePAM no
                StrictModes no
                AuthorizedKeysFile \(base.appending(path: "authorized_keys").path)
                PasswordAuthentication no
                KbdInteractiveAuthentication no
                PubkeyAuthentication yes
                LogLevel VERBOSE
                Subsystem sftp /usr/libexec/sftp-server

                """
            if let banner {
                try Self.write(banner, to: base.appending(path: "banner"))
                config += "Banner \(base.appending(path: "banner").path)\n"
            }
            try Self.write(config, to: base.appending(path: "sshd_config"))
            FileManager.default.createFile(atPath: base.appending(path: "sshd.log").path, contents: nil)
            let process = Process()
            process.executableURL = URL(filePath: "/usr/sbin/sshd")
            process.arguments = ["-D", "-e", "-f", base.appending(path: "sshd_config").path]
            process.standardError = try FileHandle(forWritingTo: base.appending(path: "sshd.log"))
            process.standardInput = FileHandle.nullDevice
            process.terminationHandler = { [exited] _ in exited.signal() }
            try process.run()
            self.process = process
            for _ in 0..<100 where !log.contains("Server listening") { Thread.sleep(forTimeInterval: 0.05) }
        }

        /// `ssh_config` for `alias`, signing in with `identity` (`id`, or the encrypted `id_enc`),
        /// with `extra` lines (each indented) at the end of its `Host` block.
        func config(identity: String, extra: [String] = []) throws -> String {
            let path = directory.appending(path: "ssh_config_\(identity)").path
            try Self.write(
                """
                Host \(Self.alias)
                  HostName 127.0.0.1
                  Port \(port)
                  User \(NSUserName())
                  IdentityFile \(directory.appending(path: identity).path)
                  IdentitiesOnly yes
                  IdentityAgent none
                  AddKeysToAgent no
                  IgnoreUnknown UseKeychain
                  UseKeychain no
                  UserKnownHostsFile \(knownHostsPath)
                  GlobalKnownHostsFile /dev/null
                  HashKnownHosts no
                  PasswordAuthentication no
                  KbdInteractiveAuthentication no

                """ + extra.map { "  \($0)\n" }.joined(), to: URL(filePath: path))
            return path
        }

        var knownHostsPath: String { directory.appending(path: "known_hosts").path }
        var knownHosts: String { (try? String(contentsOfFile: knownHostsPath, encoding: .utf8)) ?? "" }

        /// The host key's public line, `ssh-ed25519 AAAA… loopback`.
        var hostKey: String {
            (try? String(contentsOf: directory.appending(path: "host_key.pub"), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }

        /// The host key's SHA256 fingerprint, as ssh prints it.
        func hostFingerprint() throws -> String {
            let output = try Self.run(
                "/usr/bin/ssh-keygen", ["-l", "-f", directory.appending(path: "host_key.pub").path])
            return output.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        }

        /// Makes this Mac know the host's key.
        func trustHostKey() throws {
            let key = hostKey.split(separator: " ").prefix(2).joined(separator: " ")
            try Self.write("[127.0.0.1]:\(port) \(key)\n", to: URL(filePath: knownHostsPath))
        }

        var log: String {
            (try? String(contentsOf: directory.appending(path: "sshd.log"), encoding: .utf8)) ?? ""
        }

        func stop() {
            process.terminate()
            exited.wait()
            try? FileManager.default.removeItem(at: directory)
        }

        @discardableResult
        private static func run(_ executable: String, _ arguments: [String]) throws -> String {
            let process = Process()
            process.executableURL = URL(filePath: executable)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardInput = FileHandle.nullDevice
            try process.run()
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: output, as: UTF8.self)
        }

        private static func write(_ text: String, to url: URL) throws {
            try text.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }

        /// A port the kernel just handed out on 127.0.0.1.
        static func freePort() throws -> Int {
            let held = try HeldPort()
            defer { held.close() }
            return held.port
        }
    }

    /// A listening TCP socket on a port the kernel hands out on 127.0.0.1, held until `close`.
    struct HeldPort {
        let socket: Int32
        let port: Int

        init() throws {
            let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            socket = fd
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let bound = withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, length) == 0 && listen(fd, 4) == 0 && getsockname(fd, $0, &length) == 0
                }
            }
            guard bound else {
                Darwin.close(fd)
                throw CocoaError(.featureUnsupported)
            }
            port = Int(UInt16(bigEndian: address.sin_port))
        }

        func close() { Darwin.close(socket) }
    }
#endif
