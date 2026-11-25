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
            TitledTab(machineID: a, name: "omarchy", screen: .focused),
        ])
        #expect(titles == ["omarchy · DP-3", "omarchy · DP-2", "omarchy"])
    }

    /// Only the tabs that aren't mirrors are counted, so a mirror's output being named never
    /// renumbers another tab.
    @Test func numberingCountsOnlyTabsWithoutAMonitor() {
        let a = UUID()
        let titles = TabPlanning.titles([
            TitledTab(machineID: a, name: "omarchy", screen: .focused),
            TitledTab(machineID: a, name: "omarchy", screen: .named("DP-3")),
            TitledTab(machineID: a, name: "omarchy", screen: .virtual),
            TitledTab(machineID: a, name: "omarchy", screen: .virtual),
        ])
        #expect(titles == ["omarchy", "omarchy · DP-3", "omarchy", "omarchy 2"])
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
