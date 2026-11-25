import Testing

@testable import GliffTransport

@Suite struct SSHMasterCommandTests {
    let command = try! SSHMasterCommand(
        target: SSHTarget("omarchy"), socket: "/s/1-1", sshArguments: ["-p", "2222"])

    /// ssh keeps an option's first value, so the master's own come before the extra arguments.
    @Test func theMasterKeepsItsOptionsBeforeTheExtraArguments() {
        // `-T` and the four safety options.
        let safety = Array(SSHCommand.options([]).prefix(9))
        #expect(safety.last == "IPQoS=ef")
        let own = ["-o", "ControlMaster=yes", "-o", "ControlPersist=no", "-S", "/s/1-1", "-N"]
        #expect(Array(command.master.prefix(9)) == safety)
        #expect(Array(command.master.dropFirst(9).prefix(own.count)) == own)
        #expect(Array(command.master.dropFirst(9 + own.count).prefix(2)) == ["-p", "2222"])
        #expect(Array(command.master.suffix(2)) == ["--", "omarchy"])
        #expect(!command.master.contains("-M"))
    }

    @Test func theMasterCanHaveAConnectTimeout() throws {
        let timed = try SSHMasterCommand(target: SSHTarget("omarchy"), socket: "/s/1-1", connectTimeout: true)
        #expect(timed.master.contains("ConnectTimeout=10"))
    }

    static let asking = MasterAsking(config: SSHResolvedConfig(resolved: "updatehostkeys ask\n"))

    /// The master that may ask: no BatchMode, the host-key rule first (ssh keeps the first
    /// value), UpdateHostKeys off when the config would ask, and ssh's stdin /dev/null (`-n`).
    @Test func anAskingMasterHasNoBatchMode() throws {
        let master = try SSHMasterCommand(target: SSHTarget("omarchy"), socket: "/s/1-1", asking: Self.asking)
            .master
        #expect(!master.contains("BatchMode=yes"))
        #expect(Array(master.prefix(4)) == ["-T", "-n", "-o", "StrictHostKeyChecking=ask"])
        let strict = try #require(master.firstIndex(of: "StrictHostKeyChecking=ask"))
        let control = try #require(master.firstIndex(of: "ControlMaster=yes"))
        #expect(strict < control)
        #expect(master.contains("UpdateHostKeys=no"))
        #expect(master.filter { $0.hasPrefix("StrictHostKeyChecking=") }.count == 1)
        #expect(Array(master.suffix(2)) == ["--", "omarchy"])
    }

    @Test func anAskingMastersRequestsKeepTheirGuards() throws {
        let asking = try SSHMasterCommand(
            target: SSHTarget("omarchy"), socket: "/s/1-1", sshArguments: ["-p", "2222"], asking: Self.asking)
        #expect(asking.check == command.check && asking.exit == command.exit)
        #expect(asking.channel("x") == command.channel("x"))
    }

    @Test func aMasterWithoutAskingIsUnchanged() throws {
        let plain = try SSHMasterCommand(target: SSHTarget("omarchy"), socket: "/s/1-1")
        #expect(
            plain.master == [
                "-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "Compression=no",
                "-o", "IPQoS=ef", "-o", "ControlMaster=yes", "-o", "ControlPersist=no", "-S", "/s/1-1", "-N",
                "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=6", "--", "omarchy",
            ])
    }

    /// Each config value at the argv: strict `yes` kept, anything else `ask`; UpdateHostKeys
    /// turned off only for `ask`.
    @Test(arguments: [
        ("stricthostkeychecking true\nupdatehostkeys true\n", "StrictHostKeyChecking=yes", false),
        ("stricthostkeychecking accept-new\nupdatehostkeys false\n", "StrictHostKeyChecking=ask", false),
        ("stricthostkeychecking ask\nupdatehostkeys ask\n", "StrictHostKeyChecking=ask", true),
    ])
    func anAskingMasterFollowsTheConfig(_ text: String, strict: String, updateOff: Bool) throws {
        let asking = MasterAsking(config: SSHResolvedConfig(resolved: text))
        let master = try SSHMasterCommand(target: SSHTarget("omarchy"), socket: "/s/1-1", asking: asking)
            .master
        #expect(master[3] == strict)
        #expect(master.contains("UpdateHostKeys=no") == updateOff)
    }

    static let guards = [
        "-o", "ControlMaster=no", "-o", "ProxyCommand=/usr/bin/false", "-o", "BatchMode=yes",
    ]

    @Test func aChannelCannotSignInOnItsOwn() {
        #expect(
            command.channel("gliff-server --stdio")
                == ["-T", "-S", "/s/1-1"] + Self.guards + [
                    "-p", "2222", "--", "omarchy", "gliff-server --stdio",
                ])
    }

    @Test func checkAndExitOnlyEverAskTheMaster() {
        #expect(command.check == ["-S", "/s/1-1"] + Self.guards + ["-O", "check", "--", "omarchy"])
        #expect(command.exit == ["-S", "/s/1-1"] + Self.guards + ["-O", "exit", "--", "omarchy"])
    }

    /// ssh expands `%` tokens in a control path.
    @Test func aPercentInTheSocketIsEscaped() throws {
        let odd = try SSHMasterCommand(target: SSHTarget("omarchy"), socket: "/a%h/1-1")
        #expect(Array(odd.check.prefix(2)) == ["-S", "/a%%h/1-1"])
    }
}
