import Testing

@testable import GliffTransport

@Suite struct SSHMasterCommandTests {
    let command = try! SSHMasterCommand(
        target: SSHTarget("omarchy"), socket: "/s/1-1", sshArguments: ["-p", "2222"])

    /// ssh keeps an option's first value, so the master's own come before the extra arguments.
    @Test func theMasterKeepsItsOptionsBeforeTheExtraArguments() {
        // `-T` and the five safety options.
        let safety = Array(SSHCommand.options([]).prefix(11))
        #expect(safety.last == "ClearAllForwardings=yes")
        let own = [
            "-o", "ControlMaster=yes", "-o", "ControlPersist=no", "-o", "ForkAfterAuthentication=no", "-S",
            "/s/1-1", "-N",
        ]
        #expect(Array(command.master.prefix(11)) == safety)
        #expect(Array(command.master.dropFirst(11).prefix(own.count)) == own)
        #expect(Array(command.master.dropFirst(11 + own.count).prefix(2)) == ["-p", "2222"])
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
                "-o", "IPQoS=ef", "-o", "ClearAllForwardings=yes", "-o", "ControlMaster=yes", "-o",
                "ControlPersist=no", "-o", "ForkAfterAuthentication=no", "-S", "/s/1-1", "-N",
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

    static let channelOptions = [
        "-o", "ForwardAgent=no", "-o", "ForwardX11=no", "-o", "PermitLocalCommand=no", "-o",
        "RemoteCommand=none", "-o", "RequestTTY=no", "-o", "SessionType=default", "-o", "StdinNull=no", "-o",
        "ForkAfterAuthentication=no",
    ]

    @Test func aChannelCannotSignInOnItsOwn() {
        #expect(
            command.channel("gliff-server --stdio")
                == ["-T", "-S", "/s/1-1"] + Self.guards + ["-o", "ClearAllForwardings=yes"]
                + Self.channelOptions
                + ["-p", "2222", "--", "omarchy", "gliff-server --stdio"])
    }

    /// No agent, X11, local command, remote command or terminal on any channel, whatever the
    /// config says; before the extra arguments, as ssh keeps the first value.
    @Test func everyChannelCarriesTheChannelOptions() throws {
        let channel = command.channel("x")
        let clear = try #require(channel.firstIndex(of: "ClearAllForwardings=yes"))
        #expect(Array(channel[(clear + 1)...].prefix(Self.channelOptions.count)) == Self.channelOptions)
        #expect(SSHCommand.channelOptions == Self.channelOptions)
    }

    /// A forward is asked of the master without reading the config (`-F none`), whose own
    /// forwards ssh would send too.
    @Test func aForwardOnlyEverAsksTheMaster() {
        #expect(
            command.forward("127.0.0.1:3000:localhost:3000")
                == ["-S", "/s/1-1", "-F", "none"] + Self.guards + [
                    "-O", "forward", "-L", "127.0.0.1:3000:localhost:3000", "--", "omarchy",
                ])
    }

    @Test func cancelAsksTheMasterWithNoConfig() {
        #expect(
            command.cancel("[::1]:3000:localhost:3000")
                == ["-S", "/s/1-1", "-F", "none"] + Self.guards + [
                    "-O", "cancel", "-L", "[::1]:3000:localhost:3000", "--", "omarchy",
                ])
    }

    /// The spec binds 127.0.0.1 or [::1] only: `PortForward` has no bind field to ask for more.
    @Test func specsBindOnlyLoopback() throws {
        let forward = try #require(PortForward(localPort: 5173, destination: .localhost, remotePort: 5173))
        #expect(SSHForwardSpec.make(forward, on: .ipv4) == "127.0.0.1:5173:localhost:5173")
        #expect(SSHForwardSpec.make(forward, on: .ipv6) == "[::1]:5173:localhost:5173")
    }

    @Test func anIPv6DestinationIsBracketed() throws {
        let v6 = try #require(IPLiteral("2001:db8::1"))
        let v4 = try #require(IPLiteral("192.0.2.10"))
        let db = try #require(ForwardDestination(configuredHost: "db.example"))
        #expect(
            SSHForwardSpec.make(
                PortForward(localPort: 8080, destination: .address(v6), remotePort: 80)!, on: .ipv4)
                == "127.0.0.1:8080:[2001:db8::1]:80")
        #expect(
            SSHForwardSpec.make(
                PortForward(localPort: 8080, destination: .address(v4), remotePort: 80)!, on: .ipv6)
                == "[::1]:8080:192.0.2.10:80")
        #expect(
            SSHForwardSpec.make(PortForward(localPort: 5432, destination: db, remotePort: 5432)!, on: .ipv4)
                == "127.0.0.1:5432:db.example:5432")
    }

    /// A control request reads no config (`-F none`): it needs only the socket.
    @Test func checkAndExitOnlyEverAskTheMaster() {
        let ask = ["-S", "/s/1-1", "-F", "none"] + Self.guards
        #expect(command.check == ask + ["-O", "check", "--", "omarchy"])
        #expect(command.exit == ask + ["-O", "exit", "--", "omarchy"])
    }

    /// ssh expands `%` tokens in a control path.
    @Test func aPercentInTheSocketIsEscaped() throws {
        let odd = try SSHMasterCommand(target: SSHTarget("omarchy"), socket: "/a%h/1-1")
        #expect(Array(odd.check.prefix(2)) == ["-S", "/a%%h/1-1"])
    }
}
