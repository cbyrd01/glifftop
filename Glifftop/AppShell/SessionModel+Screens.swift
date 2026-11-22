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

    /// The monitor the ended session asked for by name, when the host has no such monitor
    /// connected; nil otherwise, and once the sheet has saved another screen for Try Again.
    var missingMonitor: String? {
        guard phase == .ended, sheetScreen == nil, case .named(let name) = screenChoice,
            snapshot.end?.isMissingMonitor(screenChoice) == true
        else { return nil }
        return name
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

    /// `label`, at most `shortLength` characters (the last an ellipsis), for View ▸ Screen and
    /// the options' picker: a long make and model can't widen either.
    var shortLabel: String {
        label.count <= Self.shortLength ? label : label.prefix(Self.shortLength - 1) + "…"
    }

    private static let shortLength = 60
}
