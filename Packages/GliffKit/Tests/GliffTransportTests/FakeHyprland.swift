#if os(macOS)
    import Darwin
    import Foundation
    import Testing

    /// A temporary home for a fake Hyprland host: `bin/hyprctl` answers `-j monitors` for the
    /// instances in `live` and, like the real one, prints its error on stdout for any other;
    /// `instance` makes `$XDG_RUNTIME_DIR/hypr/<signature>/.socket.sock`.
    final class FakeHyprland {
        static let monitors =
            #"[{"name":"DP-1","make":"A","model":"B","width":1920,"height":1080,"scale":1}]"#

        let root = FileManager.default.temporaryDirectory.appending(path: "sl-\(UUID().uuidString.prefix(8))")
        var runtime: URL { root.appending(path: "r") }
        var bin: URL { root.appending(path: "bin") }
        private var sockets: [Int32] = []

        init(live: [String], hyprctl: Bool = true) throws {
            try FileManager.default.createDirectory(
                at: runtime.appending(path: "hypr"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            guard hyprctl else { return }
            let cases = live.map { "\($0)) printf '%s' '\(Self.monitors)';;" }.joined()
            let script = """
                #!/bin/sh
                [ "$1 $2" = "-j monitors" ] || exit 9
                case "$HYPRLAND_INSTANCE_SIGNATURE" in \(cases) *) echo "Couldn't connect"; exit 1;; esac
                """
            let path = bin.appending(path: "hyprctl")
            try script.write(to: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        }

        /// An instance directory with a socket; later calls are newer.
        func instance(_ signature: String) throws {
            let dir = runtime.appending(path: "hypr/\(signature)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let path = dir.appending(path: ".socket.sock").path
            // sun_path holds 104 bytes, the terminating zero included.
            try #require(path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path))
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &address.sun_path) { raw in
                path.utf8CString.withUnsafeBytes { raw.copyMemory(from: $0) }
            }
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            #expect(bound == 0)
            sockets.append(fd)
            // ls -t sorts by modification time, a second apart at worst.
            try FileManager.default.setAttributes(
                [.modificationDate: Date.now.addingTimeInterval(Double(sockets.count))],
                ofItemAtPath: dir.path)
        }

        /// The `env` words that run a command on this host: its PATH, and its runtime
        /// directory unless `runtimeDirectory` is false.
        func environment(signature: String? = nil, runtimeDirectory: Bool = true) -> [String] {
            ["-i", "PATH=\(bin.path):/usr/bin:/bin"]
                + (runtimeDirectory ? ["XDG_RUNTIME_DIR=\(runtime.path)"] : [])
                + (signature.map { ["HYPRLAND_INSTANCE_SIGNATURE=\($0)"] } ?? [])
        }

        /// Runs `script` with `/bin/sh -c` on this host: its exit status and its stdout and
        /// stderr together.
        func run(_ script: String, signature: String? = nil, runtimeDirectory: Bool = true) throws
            -> (status: Int32, output: String)
        {
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/env")
            process.arguments =
                environment(signature: signature, runtimeDirectory: runtimeDirectory) + [
                    "/bin/sh", "-c", script,
                ]
            let pipe = Pipe()
            (process.standardOutput, process.standardError) = (pipe, pipe)
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }

        deinit {
            for fd in sockets { close(fd) }
            try? FileManager.default.removeItem(at: root)
        }
    }
#endif
