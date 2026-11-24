public import Foundation
import GliffTransport

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

    /// Tab titles in one window, in tab order: the machine's name, numbered from the machine's
    /// second tab ("omarchy", "omarchy 2"), as a tab shows its title alone; a tab with no
    /// machine unnumbered.
    public static func titles(_ tabs: [(machineID: UUID?, name: String)]) -> [String] {
        var seen: [UUID: Int] = [:]
        return tabs.map { tab in
            guard let id = tab.machineID else { return tab.name }
            let count = (seen[id] ?? 0) + 1
            seen[id] = count
            return count == 1 ? tab.name : "\(tab.name) \(count)"
        }
    }
}
