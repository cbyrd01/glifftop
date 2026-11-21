import GliffSession
import GliffTransport

/// Switching the window's session to another screen, and the names the picker and
/// the View menu show.
extension SessionModel {
    /// View ▸ Screen: a new session to the same host showing `choice`, keeping the window's
    /// text size and Scale to Fit. gliff-server picks its output only at start. The
    /// same choice again only once the session has ended: it tries that screen once more.
    func switchScreen(_ choice: ScreenChoice) {
        guard let destination, choice != screenChoice || snapshot.phase == .ended else { return }
        isSwitching = true
        start(destination, screen: choice)
    }
}

extension ScreenChoice {
    /// The picker's and the View menu's name for it; a monitor by its connector name.
    var label: String {
        switch self {
        case .focused: "Focused Monitor"
        case .virtual: "Virtual Screen"
        case .named(let name): name
        }
    }
}

extension RemoteScreen {
    /// "DP-3 — 2560×1440, LG Electronics LG ULTRAGEAR".
    var label: String {
        let size = "\(width)×\(height)"
        return description.isEmpty ? "\(name) — \(size)" : "\(name) — \(size), \(description)"
    }

    /// `label`, at most `menuLength` characters (the last an ellipsis), for View ▸ Screen.
    var menuLabel: String {
        label.count <= Self.menuLength ? label : label.prefix(Self.menuLength - 1) + "…"
    }

    private static let menuLength = 60
}
