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
