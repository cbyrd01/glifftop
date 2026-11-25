import Testing

@testable import GliffMachines

/// Where Show All Monitors puts each monitor's window when placing in the host's order.
@Suite struct MonitorPlacementTests {
    private let left = DisplayRect(id: 1, minX: 0, maxY: 1080)
    private let right = DisplayRect(id: 2, minX: 1920, maxY: 1080)
    private let farRight = DisplayRect(id: 3, minX: 3840, maxY: 1080)

    @Test func displaysOrderLeftToRight() {
        #expect(MonitorPlacement.displayOrder([farRight, left, right]) == [left, right, farRight])
    }

    /// AppKit's y grows upward: of two displays with the same left edge, the higher first.
    @Test func displaysOrderTopFirstWhenStacked() {
        let lower = DisplayRect(id: 4, minX: 0, maxY: 1080)
        let upper = DisplayRect(id: 5, minX: 0, maxY: 2160)
        #expect(MonitorPlacement.displayOrder([lower, upper]) == [upper, lower])
    }

    @Test func twoMonitorsOnTwoDisplays() {
        let slots = MonitorPlacement.slots(
            hostOrder: ["DP-3", "DP-2"], windows: [.new(monitor: "DP-3"), .new(monitor: "DP-2")],
            displays: [right, left])
        #expect(slots["DP-3"] == Slot(display: 1, step: 0, moves: true, fits: false))
        #expect(slots["DP-2"] == Slot(display: 2, step: 0, moves: true, fits: false))
    }

    @Test func threeMonitorsOnTwoDisplays() {
        let slots = MonitorPlacement.slots(
            hostOrder: ["DP-3", "DP-2", "DP-1"],
            windows: [.new(monitor: "DP-3"), .new(monitor: "DP-2"), .new(monitor: "DP-1")],
            displays: [left, right])
        #expect(slots["DP-1"] == Slot(display: 2, step: 1, moves: true, fits: false))
        #expect(slots["DP-2"]?.step == 0)
    }

    @Test func twoMonitorsOnThreeDisplays() {
        let slots = MonitorPlacement.slots(
            hostOrder: ["DP-3", "DP-2"], windows: [.new(monitor: "DP-3"), .new(monitor: "DP-2")],
            displays: [left, right, farRight])
        #expect(Set(slots.values.map(\.display)) == [1, 2])
    }

    /// A window already showing a monitor keeps its place, and its slot still counts.
    @Test func aShownMonitorKeepsItsSlot() {
        let slots = MonitorPlacement.slots(
            hostOrder: ["DP-3", "DP-2"], windows: [.stays(monitor: "DP-3"), .new(monitor: "DP-2")],
            displays: [left])
        #expect(slots["DP-3"] == Slot(display: 1, step: 0, moves: false, fits: false))
        #expect(slots["DP-2"] == Slot(display: 1, step: 1, moves: true, fits: false))
    }

    @Test func theKeyWindowMovesWhenAlone() {
        let slots = MonitorPlacement.slots(
            hostOrder: ["DP-3", "DP-2"],
            windows: [.new(monitor: "DP-3"), .key(monitor: "DP-2", movable: true)],
            displays: [left, right])
        #expect(slots["DP-2"] == Slot(display: 2, step: 0, moves: true, fits: true))
    }

    /// In a tab group or in full screen: it stays, and its slot is still counted.
    @Test func aTabbedKeyWindowStaysAndCounts() {
        let slots = MonitorPlacement.slots(
            hostOrder: ["DP-3", "DP-2"],
            windows: [.key(monitor: "DP-3", movable: false), .new(monitor: "DP-2")],
            displays: [left])
        #expect(slots["DP-3"] == Slot(display: 1, step: 0, moves: false, fits: false))
        #expect(slots["DP-2"] == Slot(display: 1, step: 1, moves: true, fits: false))
    }

    @Test func aVirtualScreenTakesNoSlot() {
        let slots = MonitorPlacement.slots(
            hostOrder: ["DP-3", "DP-2"],
            windows: [.key(monitor: nil, movable: true), .new(monitor: "DP-3"), .new(monitor: "DP-2")],
            displays: [left, right])
        #expect(slots.count == 2)
        #expect(slots["DP-3"]?.display == 1)
        #expect(slots["DP-2"] == Slot(display: 2, step: 0, moves: true, fits: false))
    }

    @Test func noDisplayPlacesNothing() {
        #expect(
            MonitorPlacement.slots(hostOrder: ["DP-3"], windows: [.new(monitor: "DP-3")], displays: [])
                .isEmpty)
    }

    /// Two windows of one monitor: the key window's place counts, whatever their order, and
    /// the monitor takes one step.
    @Test(arguments: [true, false])
    func theKeyWindowWinsOverAnotherOfItsMonitor(keyFirst: Bool) {
        let pair: [PlacedWindow] = [.key(monitor: "DP-3", movable: true), .stays(monitor: "DP-3")]
        let windows = (keyFirst ? pair : pair.reversed()) + [.new(monitor: "DP-2")]
        let slots = MonitorPlacement.slots(hostOrder: ["DP-3", "DP-2"], windows: windows, displays: [left])
        #expect(slots["DP-3"] == Slot(display: 1, step: 0, moves: true, fits: true))
        #expect(slots["DP-2"]?.step == 1)
    }
}
