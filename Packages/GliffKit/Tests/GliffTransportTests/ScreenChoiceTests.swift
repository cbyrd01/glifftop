import Foundation
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

    @Test(arguments: [ScreenChoice.focused, .virtual, .named("DP-2"), .named("HDMI-A-1")])
    func aChoiceRoundTrips(_ choice: ScreenChoice) throws {
        let data = try JSONEncoder().encode(choice)
        #expect(try JSONDecoder().decode(ScreenChoice.self, from: data) == choice)
    }

    /// A stored name becomes a server argument: it must be one Get Screens would offer.
    @Test(arguments: ["--headless", "auto", "a b", "", "gliff-4242"])
    func aStoredNameMustBeValid(_ name: String) throws {
        let data = try JSONEncoder().encode(["named": ["_0": name]])
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(ScreenChoice.self, from: data) }
    }
}
