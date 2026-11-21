import Testing

@testable import GliffTransport

/// What each screen choice asks gliff-server for.
@Suite struct ScreenChoiceTests {
    @Test func focusedMirrorsAuto() {
        #expect(ScreenChoice.focused.serverArguments == ["--output", "auto"])
    }

    @Test func aNamedMonitor() {
        #expect(ScreenChoice.named("DP-3").serverArguments == ["--output", "DP-3"])
    }

    @Test func virtualIsHeadless() {
        #expect(ScreenChoice.virtual.serverArguments == ["--headless"])
    }

    @Test func serverArgumentsReachTheCommand() throws {
        let command = SSHCommand(
            target: try SSHTarget("omarchy"), serverArguments: ScreenChoice.named("DP-3").serverArguments)
        #expect(command.arguments.suffix(4) == ["gliff-server", "--stdio", "--output", "DP-3"])
    }
}
