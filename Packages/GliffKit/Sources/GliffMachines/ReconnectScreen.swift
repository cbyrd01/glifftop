public import GliffSession
public import GliffTransport

/// What a window's reconnect asks the server for: its own choice, except a Focused Monitor
/// mirror's, which asks for the monitor it last showed, by name, so the reconnect restores its
/// picture though the host's focus has moved. Once a session finds that monitor missing, the
/// focused one again, at once. The window's choice stays Focused Monitor throughout.
public struct ReconnectScreen: Equatable, Sendable {
    /// The monitor the window's last Focused Monitor session streamed, until another choice
    /// streams, a session finds it missing, or it is forgotten.
    private var remembered: String?

    public init() {}

    /// A session of the window's `choice` streamed `output`: a Focused Monitor mirror's monitor
    /// (a name a monitor's could be, as it becomes a server argument); any other session none.
    public mutating func streamed(_ choice: ScreenChoice, output: String?) {
        remembered = choice == .focused ? MonitorPlanning.monitor(shownBy: .focused, output: output) : nil
    }

    /// Whether `end` says the remembered monitor is missing: then it is forgotten, and the
    /// session that asked for it is started again at once, asking for the focused monitor.
    public mutating func forgetsMissing(_ end: SessionEnd) -> Bool {
        guard let remembered, end.isMissingMonitor(.named(remembered)) else { return false }
        self.remembered = nil
        return true
    }

    /// A connection the person makes follows the host's focus afresh.
    public mutating func forget() { remembered = nil }

    /// What a reconnect of a window whose choice is `choice` asks for.
    public func screen(for choice: ScreenChoice) -> ScreenChoice {
        guard choice == .focused, let remembered else { return choice }
        return .named(remembered)
    }

    /// The monitor a window of `choice` whose session named `output` shows, or is about to: a
    /// reconnecting Focused Monitor mirror's the one its try asks for, before the output is named.
    public func monitor(shownBy choice: ScreenChoice, output: String?) -> String? {
        MonitorPlanning.monitor(shownBy: screen(for: choice), output: output)
    }
}
