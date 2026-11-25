import GliffClipboard
import GliffSession
import GliffTransport
import Testing

@testable import GliffMachines

/// Which of a host's monitors Show All Monitors opens, in what order, with what options.
@Suite struct MonitorPlanningTests {
    private func screen(_ name: String, x: Int? = nil, y: Int? = nil, focused: Bool = false) -> RemoteScreen {
        RemoteScreen(
            name: name, description: "", width: 2560, height: 1440, scale: 1, isFocused: focused, x: x, y: y)
    }

    private let source = MachineOptions(
        screen: .virtual, textSize: .f875, resolution: .automatic, scaleToFit: true, reconnects: false,
        clipboard: .shared)

    private func names(_ plan: MonitorPlan) -> [String] {
        guard case .open(let openings) = plan else { return [] }
        return openings.map(\.name)
    }

    /// A named mirror's monitor from its start; a Focused Monitor mirror's once the server names
    /// an output a monitor's name could be; a virtual screen none.
    @Test func theMonitorAWindowMirrors() {
        #expect(MonitorPlanning.monitor(shownBy: .named("DP-3"), output: nil) == "DP-3")
        #expect(MonitorPlanning.monitor(shownBy: .focused, output: "DP-2") == "DP-2")
        #expect(MonitorPlanning.monitor(shownBy: .focused, output: nil) == nil)
        #expect(MonitorPlanning.monitor(shownBy: .focused, output: "DP 2") == nil)
        #expect(MonitorPlanning.monitor(shownBy: .focused, output: "gliff-42") == nil)
        #expect(MonitorPlanning.monitor(shownBy: .virtual, output: "gliff-42") == nil)
    }

    @Test func hostOrderIsXThenYThenName() {
        let screens = [
            screen("DP-2", x: 2560, y: 0), screen("HDMI-A-1", x: 0, y: 1440), screen("DP-3", x: 0, y: 0),
            screen("DP-1", x: 2560, y: 0),
        ]
        #expect(MonitorPlanning.hostOrder(screens).map(\.name) == ["DP-3", "HDMI-A-1", "DP-1", "DP-2"])
    }

    @Test func aMonitorWithoutAPositionSortsLastByName() {
        let screens = [screen("DP-9"), screen("DP-2", x: 2560, y: 0), screen("DP-4", x: 5), screen("DP-1")]
        #expect(MonitorPlanning.hostOrder(screens).map(\.name) == ["DP-2", "DP-1", "DP-4", "DP-9"])
    }

    @Test func theFocusedMonitorOpensByName() {
        let plan = MonitorPlanning.plan(
            listed: [screen("DP-3", x: 0, y: 0, focused: true)], shown: ShownMonitors(), source: source)
        guard case .open(let openings) = plan else {
            Issue.record("expected openings, got \(plan)")
            return
        }
        #expect(openings.map(\.options.screen) == [.named("DP-3")])
    }

    /// Shown by a named mirror's name or by a Focused Monitor mirror's output: not opened again.
    @Test func shownMonitorsAreSkipped() {
        let listed = [
            screen("DP-3", x: 0, y: 0), screen("DP-2", x: 2560, y: 0), screen("DP-1", x: 5120, y: 0),
        ]
        let plan = MonitorPlanning.plan(
            listed: listed, shown: ShownMonitors(live: ["DP-3", "DP-1"]), source: source)
        #expect(names(plan) == ["DP-2"])
    }

    @Test func anEndedWindowsMonitorStartsInPlace() {
        let listed = [screen("DP-3", x: 0, y: 0), screen("DP-2", x: 2560, y: 0)]
        let plan = MonitorPlanning.plan(listed: listed, shown: ShownMonitors(ended: ["DP-2"]), source: source)
        guard case .open(let openings) = plan else {
            Issue.record("expected openings, got \(plan)")
            return
        }
        #expect(openings.map(\.inPlace) == [false, true])
        #expect(openings[1].options.screen == .named("DP-2"))
    }

    /// A monitor both shown live and with an ended window counts as shown.
    @Test func aLiveMirrorWinsOverAnEndedOne() {
        let plan = MonitorPlanning.plan(
            listed: [screen("DP-3")], shown: ShownMonitors(live: ["DP-3"], ended: ["DP-3"]), source: source)
        #expect(plan == .allShown)
    }

    /// A host's list is untrusted: at most `maxOpenings` windows open, the first in host order.
    @Test func openingsAreCapped() {
        let listed = (0..<40).map { screen("DP-\($0)", x: $0 * 100, y: 0) }
        let plan = MonitorPlanning.plan(listed: listed, shown: ShownMonitors(), source: source)
        #expect(names(plan) == (0..<MonitorPlanning.maxOpenings).map { "DP-\($0)" })
    }

    @Test func anEmptyListIsNotAllShown() {
        #expect(
            MonitorPlanning.plan(listed: [], shown: ShownMonitors(live: ["DP-3"]), source: source) == .empty)
    }

    @Test func everythingShownIsAllShown() {
        let listed = [screen("DP-3"), screen("DP-2")]
        let plan = MonitorPlanning.plan(
            listed: listed, shown: ShownMonitors(live: ["DP-2", "DP-3"]), source: source)
        #expect(plan == .allShown)
    }

    @Test func optionsAreTheSourcesWithTheMonitor() {
        let plan = MonitorPlanning.plan(listed: [screen("DP-2")], shown: ShownMonitors(), source: source)
        var expected = source
        expected.screen = .named("DP-2")
        #expect(plan == .open([MonitorOpening(name: "DP-2", options: expected, inPlace: false)]))
    }
}
