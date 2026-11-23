import Testing

@testable import GliffTransport

/// Get Screens runs one fixed command, with the same ssh safety options as a session.
@Suite struct ScreenListCommandTests {
    private let target = try! SSHTarget("user@omarchy")

    @Test func theRemoteCommandIsTheArgvTail() {
        let command = ScreenListCommand(target: target)
        let tail = command.arguments.drop { $0 != "user@omarchy" }.dropFirst()
        #expect(command.remoteCommand == tail.joined(separator: " "))
        #expect(command.remoteCommand.hasPrefix("sh -c '"))
    }

    @Test func theSafetyOptionsComeFirst() {
        let session = SSHCommand(target: target, sshArguments: ["-p", "2222"]).arguments
        let list = ScreenListCommand(target: target, sshArguments: ["-p", "2222"]).arguments
        let prefix = Array(session.prefix(through: session.firstIndex(of: "--")!))
        #expect(Array(list.prefix(prefix.count)) == prefix)
    }

    @Test func aConnectTimeoutIsAnOption() {
        var list = ScreenListCommand(target: target)
        #expect(!list.arguments.contains("ConnectTimeout=10"))
        list.connectTimeout = true
        let ours = list.arguments.firstIndex(of: "ConnectTimeout=10")
        #expect(ours != nil && ours! < list.arguments.firstIndex(of: "--")!)
    }

    @Test func theTargetFollowsTheDoubleDash() {
        let list = ScreenListCommand(target: target).arguments
        #expect(list[list.firstIndex(of: "--")! + 1] == "user@omarchy")
    }

    @Test(arguments: ["omarchy", "user@omarchy", "ssh://user@omarchy:2222"])
    func theScriptIsFixed(text: String) throws {
        let list = ScreenListCommand(target: try SSHTarget(text)).arguments
        let after = Array(list.suffix(from: list.firstIndex(of: "--")! + 2))
        #expect(after == ["sh", "-c", SSHCommand.shellQuoted(ScreenListCommand.script)])
    }

    @Test func theScriptAsksHyprctlForMonitors() {
        #expect(ScreenListCommand.script.contains("HYPRLAND_INSTANCE_SIGNATURE=$sig hyprctl -j monitors"))
        #expect(!ScreenListCommand.script.contains("gliff-server"))
    }
}
