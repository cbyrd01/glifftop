import GliffMachines
import GliffSession
import GliffTransport

/// The window's title and subtitle, and the state word the status bar shows: from values set
/// only when they change, never from the stats each second.
extension SessionModel {
    /// The machine's name (the host until it has one) while a session is shown; the app's name
    /// otherwise, and when the session never started (no host left to name).
    var title: String { isActive && !host.isEmpty ? machine?.name ?? host : "Glifftop" }

    /// The monitor a mirror shows, while a session is shown: a named mirror's from its start, a
    /// Focused Monitor mirror's once the server names its output (a name a monitor's must be).
    var mirroredMonitor: String? {
        titled.screen.flatMap { MonitorPlanning.monitor(shownBy: $0, output: outputName) }
    }

    /// The window as `TabPlanning` titles it: what it shows only while a session is shown.
    private var titled: TitledTab {
        let shown = isActive && !host.isEmpty
        return TitledTab(
            machineID: machine?.id, name: title, screen: shown ? screenChoice : nil, output: outputName)
    }

    /// The window's title, among its tabs too: a mirror's names its monitor ("omarchy · DP-3");
    /// another tab of a machine open in an earlier tab is numbered ("omarchy 2").
    var tabTitle: String {
        if let tabGroup {
            let models = OpenSessions.shared.models
            let tabs = tabGroup.tabs.compactMap { number in models.first { $0.tabGroup?.window == number } }
            let titles = TabPlanning.titles(tabs.map(\.titled))
            if let index = tabs.firstIndex(where: { $0 === self }) { return titles[index] }
        }
        return TabPlanning.title(of: titled)
    }

    /// While a session is shown, the state, after the screen unless the title names it:
    /// "Connected" for a named mirror, "Virtual Screen · Connected" otherwise.
    var subtitle: String {
        guard isActive else { return "" }
        if case .named = screenChoice, mirroredMonitor != nil { return stateWord }
        return "\(screenChoice.label) · \(stateWord)"
    }

    /// Connecting, Connected, Interrupted, Reconnecting, Disconnected, or Couldn't Connect.
    var stateWord: String {
        if isReconnecting { return "Reconnecting" }
        return switch phase {
        case .idle, .connecting, .handshaking, .waitingForVideo: "Connecting"
        case .streaming: isInterrupted ? "Interrupted" : "Connected"
        case .ended: neverConnected ? "Couldn't Connect" : "Disconnected"
        }
    }

    /// The session ended without ever getting through: it never streamed, it isn't a reconnect
    /// of one that did, and this Mac didn't end it (`.disconnected`).
    var neverConnected: Bool {
        phase == .ended && !host.isEmpty && !recorded && !keepsWindow && snapshot.end != .disconnected
    }

    /// Whether Disconnect has a session to end.
    var canDisconnect: Bool { isActive && (phase != .ended || isReconnecting) }

    /// Whether the window shows one of the model's own sheets or alerts: the machine sheet, a
    /// sign-in question, the clipboard's or Show All Monitors'. New Tab waits for it; any other
    /// sheet in the group (another tab's, a view's own alert) leaves the new window on its own
    /// (`WindowTabbing`).
    var showsSheet: Bool { showsQuestion || monitorsAlert != nil }

    /// Show All Monitors' alert, once no other sheet of the model's shows (a listing's answer
    /// may come while one does). Dismissing it clears it.
    var showsMonitorsAlert: Bool {
        get { monitorsAlert != nil && !showsQuestion }
        set { if !newValue { monitorsAlert = nil } }
    }

    private var showsQuestion: Bool { machineEdit != nil || signIn.current != nil || askingClipboard != nil }
}
