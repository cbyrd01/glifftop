#if os(macOS)
    import Darwin
    import Foundation
    import Testing

    @testable import GliffTransport

    /// `ScreenListCommand.script` itself, run by /bin/sh against a fake `hyprctl` and fake
    /// Hyprland instance directories (`$XDG_RUNTIME_DIR/hypr/<signature>/.socket.sock`).
    @Suite(.timeLimit(.minutes(1))) struct ScreenListScriptTests {
        private static let monitors =
            #"[{"name":"DP-1","make":"A","model":"B","width":1920,"height":1080,"scale":1}]"#

        /// A temporary home for the fake: `bin/hyprctl` answers for the instances in `live`
        /// and, like the real one, prints its error on stdout for any other.
        private final class Host {
            let root = FileManager.default.temporaryDirectory.appending(
                path: "sl-\(UUID().uuidString.prefix(8))")
            var runtime: URL { root.appending(path: "r") }
            var bin: URL { root.appending(path: "bin") }
            private var sockets: [Int32] = []

            init(live: [String], hyprctl: Bool = true) throws {
                try FileManager.default.createDirectory(
                    at: runtime.appending(path: "hypr"), withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
                guard hyprctl else { return }
                let cases = live.map { "\($0)) printf '%s' '\(ScreenListScriptTests.monitors)';;" }.joined()
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

            func list(signature: String = "") async throws(ScreenListError) -> [RemoteScreen] {
                try await ScreenLister(
                    executable: URL(filePath: "/usr/bin/env"),
                    arguments: [
                        "PATH=\(bin.path):/usr/bin:/bin", "XDG_RUNTIME_DIR=\(runtime.path)",
                        "HYPRLAND_INSTANCE_SIGNATURE=\(signature)", "/bin/sh", "-c", ScreenListCommand.script,
                    ], timeout: .seconds(10)
                ).screens()
            }

            deinit {
                for fd in sockets { close(fd) }
                try? FileManager.default.removeItem(at: root)
            }
        }

        private func failure(_ host: Host, signature: String = "") async -> ScreenListError? {
            do {
                _ = try await host.list(signature: signature)
                return nil
            } catch {
                return error
            }
        }

        @Test func theNewestInstanceAnswers() async throws {
            let host = try Host(live: ["new"])
            try host.instance("old")
            try host.instance("new")
            #expect(try await host.list().map(\.name) == ["DP-1"])
        }

        /// A crashed compositor's newer directory is passed over (upstream `discover_in`).
        @Test func aDeadNewerInstanceIsPassedOver() async throws {
            let host = try Host(live: ["live"])
            try host.instance("live")
            try host.instance("crashed")
            #expect(try await host.list().map(\.name) == ["DP-1"])
        }

        /// A signature that starts with digits is a signature, not an index.
        @Test func theSessionsOwnSignatureComesFirst() async throws {
            let host = try Host(live: ["4520b30d_17_1"])
            try host.instance("4520b30d_17_1")
            try host.instance("newer")
            #expect(try await host.list(signature: "4520b30d_17_1").map(\.name) == ["DP-1"])
        }

        @Test func noInstanceSaysSo() async throws {
            let host = try Host(live: [])
            #expect(await failure(host) == .failed(.other("no Hyprland session is running")))
        }

        @Test func noAnsweringInstanceSaysSo() async throws {
            let host = try Host(live: [])
            try host.instance("crashed")
            #expect(await failure(host) == .failed(.other("no Hyprland session is running")))
        }

        @Test func aMissingHyprctlSaysSo() async throws {
            let host = try Host(live: [], hyprctl: false)
            try host.instance("a")
            #expect(
                await failure(host)
                    == .failed(.other("hyprctl isn't installed on the host, or isn't on its PATH.")))
        }

        /// csh and tcsh refuse a newline inside single quotes.
        @Test func theScriptIsOneLine() {
            #expect(!ScreenListCommand.script.contains("\n"))
            #expect(!ScreenListCommand.script.contains("'"))
        }
    }
#endif
