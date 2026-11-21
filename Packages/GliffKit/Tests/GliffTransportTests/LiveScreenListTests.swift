#if os(macOS)
    import Foundation
    import GliffTransport
    import Testing

    /// Get Screens against a real host: off unless `GLIFFTOP_LIVE_HOST` names an ssh
    /// destination, as `LiveSessionTests`. Read-only: it only lists the monitors. Only numbers
    /// are reported, as the attachment `live-screens.txt`.
    @Suite(
        .enabled(
            if: ProcessInfo.processInfo.environment["GLIFFTOP_LIVE_HOST"] != nil,
            "set GLIFFTOP_LIVE_HOST to run against a real host"),
        .timeLimit(.minutes(2)))
    struct LiveScreenListTests {
        @Test func listsTheHostsMonitors() async throws {
            let host = try #require(ProcessInfo.processInfo.environment["GLIFFTOP_LIVE_HOST"])
            let lister = ScreenLister(command: ScreenListCommand(target: try SSHTarget(host)))
            let screens = try await lister.screens()
            #expect(!screens.isEmpty)
            #expect(screens.filter(\.isFocused).count <= 1)
            #expect(Set(screens.map(\.name)).count == screens.count)
            Attachment.record(
                "live: \(screens.count) screens, \(screens.filter(\.isFocused).count) focused; "
                    + screens.map { "\($0.width)×\($0.height) at \($0.scale)" }.joined(separator: ", "),
                named: "live-screens.txt")
        }
    }
#endif
