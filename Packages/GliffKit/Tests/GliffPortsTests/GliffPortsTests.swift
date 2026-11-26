import Testing

@testable import GliffPorts

struct GliffPortsTests {
    /// The module logs under the app's subsystem, in a category of its own.
    @Test func theModuleLogsUnderTheAppsSubsystem() {
        #expect(GliffPorts.subsystem == "me.cbyrd.Glifftop")
        #expect(GliffPorts.category == "GliffPorts")
    }
}
