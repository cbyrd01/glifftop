import Foundation
import GliffSession
import GliffTransport
import Testing

@testable import GliffMachines

/// What a new tab starts with, and the titles of a window's tabs.
@Suite struct TabPlanningTests {
    private let monitor = MachineOptions(screen: .named("DP-1"), textSize: .f875, scaleToFit: true)

    @Test func aFirstTabKeepsTheMachinesScreen() {
        #expect(TabPlanning.options(monitor, openElsewhere: false) == monitor)
    }

    /// The machine is open already: the new tab is a screen of its own, everything else as
    /// the machine has it.
    @Test func aSecondTabIsAVirtualScreen() {
        var expected = monitor
        expected.screen = .virtual
        #expect(TabPlanning.options(monitor, openElsewhere: true) == expected)
    }

    /// A tab shows its title alone: every tab of one machine after the first is numbered, in
    /// tab order.
    @Test func sameMachineTabsAreNumbered() {
        let (a, b) = (UUID(), UUID())
        let titles = TabPlanning.titles([
            TitledTab(machineID: a, name: "omarchy", screen: .virtual), TitledTab(machineID: b, name: "box"),
            TitledTab(machineID: a, name: "omarchy", screen: .virtual),
            TitledTab(machineID: a, name: "omarchy", screen: .virtual),
        ])
        #expect(titles == ["omarchy", "box", "omarchy 2", "omarchy 3"])
    }

    /// A tab still on the machine list has no machine: its name, never a number.
    @Test func noMachineIsNotNumbered() {
        let titles = TabPlanning.titles([TitledTab(name: "Glifftop"), TitledTab(name: "Glifftop")])
        #expect(titles == ["Glifftop", "Glifftop"])
    }

    /// A mirror is titled by its monitor: a named one from its start, a Focused Monitor one
    /// once the server names its output.
    @Test func aMonitorsTitleIsNeverNumbered() {
        let a = UUID()
        let titles = TabPlanning.titles([
            TitledTab(machineID: a, name: "omarchy", screen: .named("DP-3")),
            TitledTab(machineID: a, name: "omarchy", screen: .focused, output: "DP-2"),
        ])
        #expect(titles == ["omarchy · DP-3", "omarchy · DP-2"])
    }

    /// A mirror whose monitor is known isn't counted among the machine's tabs; a Focused
    /// Monitor mirror whose output isn't named yet is, so no two tabs read the same.
    @Test func numberingCountsOnlyTabsWithoutAMonitor() {
        let a = UUID()
        let titles = TabPlanning.titles([
            TitledTab(machineID: a, name: "omarchy", screen: .focused),
            TitledTab(machineID: a, name: "omarchy", screen: .named("DP-3")),
            TitledTab(machineID: a, name: "omarchy", screen: .virtual),
            TitledTab(machineID: a, name: "omarchy", screen: .virtual),
        ])
        #expect(titles == ["omarchy", "omarchy · DP-3", "omarchy 2", "omarchy 3"])
    }

    /// A saved machine and an unsaved host of the same name, on one monitor: the second is
    /// numbered, as the two would read the same.
    @Test func mirrorsThatReadTheSameAreNumbered() {
        let titles = TabPlanning.titles([
            TitledTab(machineID: UUID(), name: "omarchy", screen: .named("DP-3")),
            TitledTab(name: "omarchy", screen: .named("DP-3")),
        ])
        #expect(titles == ["omarchy · DP-3", "omarchy · DP-3 2"])
    }

    /// An unsaved host is numbered apart from every saved machine, whatever it is called.
    @Test func anUnsavedHostIsNumberedApartFromMachines() {
        let a = UUID()
        let titles = TabPlanning.titles([
            TitledTab(machineID: a, name: "omarchy", screen: .named("DP-3")),
            TitledTab(name: a.uuidString, screen: .named("DP-3")),
        ])
        #expect(titles == ["omarchy · DP-3", "\(a.uuidString) · DP-3"])
    }

    /// Two mirrors of one monitor (chosen by hand): the second is numbered.
    @Test func aRepeatedMonitorIsNumbered() {
        let a = UUID()
        let titles = TabPlanning.titles([
            TitledTab(machineID: a, name: "omarchy", screen: .named("DP-3")),
            TitledTab(machineID: a, name: "omarchy", screen: .focused, output: "DP-3"),
            TitledTab(name: "box", screen: .named("DP-3")),
        ])
        #expect(titles == ["omarchy · DP-3", "omarchy · DP-3 2", "box · DP-3"])
    }

    @Test func aWindowsTitleNamesItsMonitor() {
        #expect(TabPlanning.title(of: TitledTab(name: "omarchy", screen: .named("DP-3"))) == "omarchy · DP-3")
        #expect(TabPlanning.title(of: TitledTab(name: "omarchy", screen: .virtual)) == "omarchy")
        #expect(
            TabPlanning.title(of: TitledTab(name: "omarchy", screen: .focused, output: "gliff-7"))
                == "omarchy")
    }
}
