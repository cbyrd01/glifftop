import GliffSession
import GliffTransport
import Testing

@testable import GliffMachines

/// What a reconnect asks the server for: a Focused Monitor mirror's, the monitor it last showed.
@Suite struct ReconnectScreenTests {
    private func streamed(_ choice: ScreenChoice, output: String?) -> ReconnectScreen {
        var screen = ReconnectScreen()
        screen.streamed(choice, output: output)
        return screen
    }

    /// The host's focus may have moved since: the reconnect restores the picture the window had.
    @Test func aFocusedMonitorMirrorAsksForTheMonitorItLastShowed() {
        #expect(streamed(.focused, output: "DP-3").screen(for: .focused) == .named("DP-3"))
    }

    @Test func aWindowThatNeverStreamedANamedOutputAsksForTheFocusedMonitor() {
        #expect(ReconnectScreen().screen(for: .focused) == .focused)
        #expect(streamed(.focused, output: nil).screen(for: .focused) == .focused)
        // Never a name a monitor's couldn't be: it becomes a server argument.
        #expect(streamed(.focused, output: "-x").screen(for: .focused) == .focused)
        #expect(streamed(.focused, output: "gliff-42").screen(for: .focused) == .focused)
    }

    @Test func otherChoicesAskForThemselves() {
        let screen = streamed(.focused, output: "DP-3")
        #expect(screen.screen(for: .virtual) == .virtual)
        #expect(screen.screen(for: .named("DP-2")) == .named("DP-2"))
    }

    /// A session of another choice streamed since: it showed no Focused Monitor mirror's monitor.
    @Test func anotherChoiceStreamingForgetsTheMonitor() {
        var screen = streamed(.focused, output: "DP-3")
        screen.streamed(.virtual, output: "gliff-42")
        #expect(screen.screen(for: .focused) == .focused)
        screen.streamed(.focused, output: "DP-2")
        screen.streamed(.named("DP-3"), output: "DP-3")
        #expect(screen.screen(for: .focused) == .focused)
    }

    @Test func theLatestFocusedSessionsMonitorIsKept() {
        var screen = streamed(.focused, output: "DP-3")
        screen.streamed(.focused, output: "DP-2")
        #expect(screen.screen(for: .focused) == .named("DP-2"))
    }

    /// The monitor is gone: the window asks for the focused monitor at once, and from then on.
    @Test func aMissingMonitorFallsBackToTheFocusedOne() {
        var screen = streamed(.focused, output: "DP-3")
        let missing = SessionEnd.serverSetupFailed("no output DP-3")
        let fallsBack = screen.forgetsMissing(missing)
        #expect(fallsBack)
        #expect(screen.screen(for: .focused) == .focused)
        // Forgotten: a second such end is the session's own, shown as it is.
        let again = screen.forgetsMissing(missing)
        #expect(!again)
        #expect(screen.screen(for: .focused) == .focused)
    }

    @Test func anyOtherEndKeepsTheMonitor() {
        var screen = streamed(.focused, output: "DP-3")
        for end: SessionEnd in [
            .connectionLost, .connectFailed(.unreachable), .serverSetupFailed("no output DP-2"),
            .serverSetupFailed("encoder failed"),
        ] {
            let fallsBack = screen.forgetsMissing(end)
            #expect(!fallsBack)
        }
        #expect(screen.screen(for: .focused) == .named("DP-3"))
        var none = ReconnectScreen()
        let fallsBack = none.forgetsMissing(.serverSetupFailed("no output DP-3"))
        #expect(!fallsBack)
    }

    /// Show All Monitors counts a reconnecting Focused Monitor mirror as showing the monitor
    /// its try asks for, before the server names the output.
    @Test func theMonitorAWindowShowsOrIsAboutToShow() {
        let screen = streamed(.focused, output: "DP-3")
        #expect(screen.monitor(shownBy: .focused, output: nil) == "DP-3")
        #expect(screen.monitor(shownBy: .focused, output: "DP-3") == "DP-3")
        #expect(ReconnectScreen().monitor(shownBy: .focused, output: nil) == nil)
        #expect(ReconnectScreen().monitor(shownBy: .focused, output: "DP-2") == "DP-2")
        #expect(screen.monitor(shownBy: .named("DP-2"), output: nil) == "DP-2")
        #expect(screen.monitor(shownBy: .virtual, output: "gliff-42") == nil)
    }

    @Test func forgettingAsksForTheFocusedMonitor() {
        var screen = streamed(.focused, output: "DP-3")
        screen.forget()
        #expect(screen.screen(for: .focused) == .focused)
    }
}
