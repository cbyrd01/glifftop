import GliffSession

/// The window's title and subtitle, and the state word the status bar shows: from values set
/// only when they change, never from the stats each second.
extension SessionModel {
    /// The host while a session is shown; the app's name otherwise.
    var title: String { isActive ? host : "Glifftop" }

    /// "Virtual Screen · Connected": the screen and the state, while a session is shown.
    var subtitle: String { isActive ? "\(screenChoice.label) · \(stateWord)" : "" }

    /// Connecting, Connected, Interrupted or Disconnected.
    var stateWord: String {
        switch phase {
        case .idle, .connecting, .handshaking, .waitingForVideo: "Connecting"
        case .streaming: isInterrupted ? "Interrupted" : "Connected"
        case .ended: "Disconnected"
        }
    }

    /// Whether Disconnect has a session to end.
    var canDisconnect: Bool { isActive && phase != .ended }
}
