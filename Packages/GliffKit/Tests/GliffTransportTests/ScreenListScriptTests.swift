#if os(macOS)
    import Foundation
    import Testing

    @testable import GliffTransport

    /// `ScreenListCommand.script` itself, run by /bin/sh against a fake `hyprctl` and fake
    /// Hyprland instance directories (`$XDG_RUNTIME_DIR/hypr/<signature>/.socket.sock`).
    @Suite(.timeLimit(.minutes(1))) struct ScreenListScriptTests {
        private func failure(_ host: FakeHyprland, signature: String = "") async -> ScreenListError? {
            do {
                _ = try await host.list(signature: signature)
                return nil
            } catch {
                return error
            }
        }

        @Test func theNewestInstanceAnswers() async throws {
            let host = try FakeHyprland(live: ["new"])
            try host.instance("old")
            try host.instance("new")
            #expect(try await host.list().map(\.name) == ["DP-1"])
        }

        /// A crashed compositor's newer directory is passed over (upstream `discover_in`).
        @Test func aDeadNewerInstanceIsPassedOver() async throws {
            let host = try FakeHyprland(live: ["live"])
            try host.instance("live")
            try host.instance("crashed")
            #expect(try await host.list().map(\.name) == ["DP-1"])
        }

        /// A signature that starts with digits is a signature, not an index.
        @Test func theSessionsOwnSignatureComesFirst() async throws {
            let host = try FakeHyprland(live: ["4520b30d_17_1"])
            try host.instance("4520b30d_17_1")
            try host.instance("newer")
            #expect(try await host.list(signature: "4520b30d_17_1").map(\.name) == ["DP-1"])
        }

        @Test func noInstanceSaysSo() async throws {
            let host = try FakeHyprland(live: [])
            #expect(await failure(host) == .failed(.other("no Hyprland session is running")))
        }

        @Test func noAnsweringInstanceSaysSo() async throws {
            let host = try FakeHyprland(live: [])
            try host.instance("crashed")
            #expect(await failure(host) == .failed(.other("no Hyprland session is running")))
        }

        @Test func aMissingHyprctlSaysSo() async throws {
            let host = try FakeHyprland(live: [], hyprctl: false)
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

    extension FakeHyprland {
        func list(signature: String = "") async throws(ScreenListError) -> [RemoteScreen] {
            try await ScreenLister(
                executable: URL(filePath: "/usr/bin/env"),
                arguments: environment(signature: signature) + ["/bin/sh", "-c", ScreenListCommand.script],
                timeout: .seconds(10)
            ).screens()
        }
    }
#endif
