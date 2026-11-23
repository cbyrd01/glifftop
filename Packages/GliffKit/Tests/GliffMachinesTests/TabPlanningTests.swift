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
            (machineID: a, name: "omarchy"), (machineID: b, name: "box"), (machineID: a, name: "omarchy"),
            (machineID: a, name: "omarchy"),
        ])
        #expect(titles == ["omarchy", "box", "omarchy 2", "omarchy 3"])
    }

    /// A tab still on the machine list has no machine: its name, never a number.
    @Test func noMachineIsNotNumbered() {
        let titles = TabPlanning.titles([
            (machineID: nil, name: "Glifftop"), (machineID: nil, name: "Glifftop"),
        ])
        #expect(titles == ["Glifftop", "Glifftop"])
    }
}
