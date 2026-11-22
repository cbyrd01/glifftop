import Testing

@testable import GliffTransport

@Suite struct SSHCommandTests {
    private let target = try! SSHTarget("user@omarchy")

    @Test func plainCommand() {
        let command = SSHCommand(target: target, sshArguments: [], serverArguments: [])
        #expect(
            command.arguments == [
                "-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "Compression=no", "-o",
                "IPQoS=ef", "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=6", "--",
                "user@omarchy", "gliff-server", "--stdio",
            ])
        #expect(SSHCommand.executable == "/usr/bin/ssh")
    }

    @Test func extraArgumentsLandAroundTheTarget() {
        let command = SSHCommand(
            target: target, sshArguments: ["-p", "2222"], serverArguments: ["--output", "DP-2"])
        #expect(
            command.arguments == [
                "-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "Compression=no", "-o",
                "IPQoS=ef", "-p", "2222", "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=6",
                "--", "user@omarchy", "gliff-server", "--stdio", "--output", "DP-2",
            ])
    }

    /// Never accept an unknown host key silently. ssh keeps the first value it
    /// sees, so ours comes before any extra arguments and the person's ssh_config.
    @Test func pinsStrictHostKeyCheckingFirst() {
        let command = SSHCommand(
            target: target, sshArguments: ["-o", "StrictHostKeyChecking=accept-new"], serverArguments: [])
        let pinned = command.arguments.firstIndex(of: "StrictHostKeyChecking=yes")
        let extra = command.arguments.firstIndex(of: "StrictHostKeyChecking=accept-new")
        #expect(pinned != nil && extra != nil && pinned! < extra!)
    }

    /// OpenSSH 10 maps the old `lowdelay` keyword to no marking at all; `ef` marks both
    /// interactive and bulk traffic (checked with `ssh -G`).
    @Test func marksTrafficExpedited() {
        let command = SSHCommand(target: target)
        #expect(command.arguments.contains("IPQoS=ef"))
        #expect(!command.arguments.contains("IPQoS=lowdelay"))
    }

    /// A dead link ends after about a minute (6 keepalives 10 s apart unanswered) rather than
    /// TCP's minutes; a shorter outage survives (no reconnect yet). Extra arguments come first,
    /// so they can change it: ssh keeps the first value it sees.
    @Test func keepalivesEndADeadLink() {
        let command = SSHCommand(
            target: target, sshArguments: ["-o", "ServerAliveInterval=30"], serverArguments: [])
        let theirs = command.arguments.firstIndex(of: "ServerAliveInterval=30")
        let ours = command.arguments.firstIndex(of: "ServerAliveInterval=10")
        #expect(theirs != nil && ours != nil && theirs! < ours!)
        #expect(command.arguments.contains("ServerAliveCountMax=6"))
    }

    /// With `connectTimeout` (`SSHConnectTimeout` decides), a host that drops packets fails in
    /// 10 s; after the extra arguments, so they can change it, and before `--`.
    @Test func aConnectTimeoutFollowsTheExtraArguments() {
        #expect(!SSHCommand(target: target).arguments.contains("ConnectTimeout=10"))
        var command = SSHCommand(target: target, sshArguments: ["-o", "ConnectTimeout=60"])
        command.connectTimeout = true
        let theirs = command.arguments.firstIndex(of: "ConnectTimeout=60")
        let ours = command.arguments.firstIndex(of: "ConnectTimeout=10")
        let dashes = command.arguments.firstIndex(of: "--")
        #expect(theirs != nil && ours != nil && dashes != nil && theirs! < ours! && ours! < dashes!)
    }

    /// The remote login shell parses the command line ssh sends, so each server argument is
    /// quoted unless it is plainly safe.
    @Test func serverArgumentsAreShellQuoted() {
        let command = SSHCommand(
            target: target, serverArguments: ["--output", "DP 2;rm -rf ~", "it's", "", "DP-2"])
        #expect(
            Array(command.arguments.suffix(7)) == [
                "gliff-server", "--stdio", "--output", "'DP 2;rm -rf ~'", "'it'\\''s'", "''", "DP-2",
            ])
    }
}
