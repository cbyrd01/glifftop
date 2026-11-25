public import Foundation
public import GliffTransport

/// A tab to title: its machine (nil before one is saved, and without a session), its name (the
/// machine's, else the host as typed, else the app's), and what its session shows (nil
/// without a session), with the output the server named.
public struct TitledTab: Sendable {
    public var machineID: UUID?
    public var name: String
    public var screen: ScreenChoice?
    public var output: String?

    public init(machineID: UUID? = nil, name: String, screen: ScreenChoice? = nil, output: String? = nil) {
        (self.machineID, self.name, self.screen, self.output) = (machineID, name, screen, output)
    }

    /// The monitor the tab mirrors, once known.
    var monitor: String? { screen.flatMap { MonitorPlanning.monitor(shownBy: $0, output: output) } }
}

/// The rules for tabs: what a new tab to a machine starts with, and what each tab is titled.
public enum TabPlanning {
    /// The options a new tab starts with: the machine's, with the screen `.virtual` when the
    /// machine is already open in another tab or window (a second screen of its own, not a
    /// second view of the same one).
    public static func options(_ machine: MachineOptions, openElsewhere: Bool) -> MachineOptions {
        var options = machine
        if openElsewhere { options.screen = .virtual }
        return options
    }

    /// A window's title: its name, then the monitor it mirrors once known ("omarchy · DP-3").
    public static func title(of tab: TitledTab) -> String {
        tab.monitor.map { "\(tab.name) · \($0)" } ?? tab.name
    }

    /// Tab titles in one window, in tab order, as a tab shows its title alone. A mirror whose
    /// monitor is known is titled by it, numbered only from a second mirror that reads the
    /// same ("omarchy · DP-3 2"). Other tabs, a Focused Monitor mirror whose output isn't named
    /// yet among them, are numbered among the machine's ("omarchy", "omarchy 2"); a tab with no
    /// machine is unnumbered.
    public static func titles(_ tabs: [TitledTab]) -> [String] {
        var seen: [Key: Int] = [:]
        return tabs.map { tab in
            let title = title(of: tab)
            let key: Key
            if tab.monitor != nil {
                key = .mirror(title)
            } else {
                guard let id = tab.machineID else { return title }
                key = .machine(id)
            }
            let count = (seen[key] ?? 0) + 1
            seen[key] = count
            return count == 1 ? title : "\(title) \(count)"
        }
    }

    private enum Key: Hashable {
        case mirror(String)
        case machine(UUID)
    }
}
