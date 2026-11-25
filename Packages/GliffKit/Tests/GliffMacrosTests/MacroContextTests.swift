import GliffTransport
import Testing

@testable import GliffMacros

/// What a run's environment says: exactly spec 3.5's table per moment, each value checked.
@Suite struct MacroContextTests {
    @Test(arguments: MacroMoment.allCases)
    func exportsMatchTheTablePerMoment(_ moment: MacroMoment) throws {
        let context = try MacroContext(
            moment: moment, reconnecting: true, screen: .named("DP-1"), output: "DP-1", headless: false)
        var expected = [
            ("GLIFF_MOMENT", moment.rawValue), ("GLIFF_RECONNECT", "1"), ("GLIFF_SCREEN", "monitor"),
            ("GLIFF_MONITOR", "DP-1"),
        ]
        if moment != .before { expected += [("GLIFF_OUTPUT", "DP-1"), ("GLIFF_HEADLESS", "0")] }
        #expect(context.exports.map(\.name) == expected.map(\.0))
        #expect(context.exports.map(\.value) == expected.map(\.1))
    }

    @Test func aVirtualScreenNamesNoMonitor() throws {
        let context = try MacroContext(
            moment: .ready, reconnecting: false, screen: .virtual, output: "gliff-4242", headless: true)
        #expect(
            context.exports.map { "\($0.name)=\($0.value)" } == [
                "GLIFF_MOMENT=ready", "GLIFF_RECONNECT=0", "GLIFF_SCREEN=virtual", "GLIFF_OUTPUT=gliff-4242",
                "GLIFF_HEADLESS=1",
            ])
        let focused = try MacroContext(moment: .manual, reconnecting: false, screen: .focused)
        #expect(focused.exports.map(\.value) == ["manual", "0", "focused"])
    }

    @Test(arguments: ["-x", "auto", String(repeating: "a", count: 65), "a b", "a'b", ""])
    func aBadOutputNameRefusesTheRun(_ name: String) {
        #expect(throws: MacroContextError.badOutputName) {
            try MacroContext(
                moment: .ready, reconnecting: false, screen: .focused, output: name, headless: false)
        }
    }

    @Test(arguments: ["-x", "a b", "a'b", "gliff-4242"])
    func aBadMonitorNameRefusesTheRun(_ name: String) {
        #expect(throws: MacroContextError.badMonitorName) {
            try MacroContext(moment: .before, reconnecting: false, screen: .named(name))
        }
    }

    @Test func noDestinationOrNameIsExported() throws {
        let allowed: Set = [
            "GLIFF_MOMENT", "GLIFF_RECONNECT", "GLIFF_SCREEN", "GLIFF_MONITOR", "GLIFF_OUTPUT",
            "GLIFF_HEADLESS",
        ]
        #expect(Set(MacroContext.variables) == allowed)
        for moment in MacroMoment.allCases {
            let context = try MacroContext(
                moment: moment, reconnecting: false, screen: .named("DP-1"), output: "DP-1", headless: false)
            #expect(Set(context.exports.map(\.name)).isSubset(of: allowed))
        }
    }

    /// A `before` run has no session, so a leftover output name is dropped, not judged.
    @Test func aBeforeRunIgnoresAnOutputName() throws {
        let context = try MacroContext(
            moment: .before, reconnecting: false, screen: .focused, output: "a b", headless: false)
        #expect(context.output == nil && context.headless == nil)
    }

    @Test(arguments: MacroMoment.allCases)
    func thePreviewShowsThePlaceholder(_ moment: MacroMoment) {
        let exports = MacroContext.preview(for: moment, screen: .virtual).exports
        let output = exports.first { $0.name == "GLIFF_OUTPUT" }?.value
        #expect(output == (moment == .before ? nil : "(the screen's name)"))
        #expect(exports.first { $0.name == "GLIFF_HEADLESS" }?.value == (moment == .before ? nil : "1"))
    }
}
