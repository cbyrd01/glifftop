import GliffMachines
import GliffSession

/// The window's title and subtitle, and the state word the status bar shows: from values set
/// only when they change, never from the stats each second.
extension SessionModel {
    /// The machine's name (the host until it has one) while a session is shown; the app's name
    /// otherwise, and when the session never started (no host left to name).
    var title: String { isActive && !host.isEmpty ? machine?.name ?? host : "Glifftop" }

    /// "Virtual Screen · Connected": the screen and the state, while a session is shown.
    var subtitle: String { isActive ? "\(screenChoice.label) · \(stateWord)" : "" }

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
}
