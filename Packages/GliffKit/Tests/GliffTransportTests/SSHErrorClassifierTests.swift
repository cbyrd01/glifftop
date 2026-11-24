import Testing

@testable import GliffTransport

@Suite struct SSHErrorClassifierTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let stderr: String
        let status: Int32
        let failure: ConnectFailure
        var testDescription: String { "\(status) \(stderr.prefix(40))" }
    }

    static let cases: [Case] = [
        Case(
            stderr: "No ED25519 host key is known for omarchy and you have requested strict checking.\n"
                + "Host key verification failed.\n", status: 255, failure: .unknownHostKey),
        Case(
            stderr: "@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@\n"
                + "@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @\n"
                + "Host key verification failed.\n", status: 255, failure: .changedHostKey),
        Case(
            stderr:
                "sign_and_send_pubkey: signing failed for ED25519 \"key\" from agent: agent refused operation\n"
                + "user@omarchy: Permission denied (publickey).\n", status: 255, failure: .agentRefused),
        Case(
            stderr: "user@omarchy: Permission denied (publickey).\n", status: 255, failure: .permissionDenied
        ),
        Case(
            stderr: "ssh: Could not resolve hostname nope: nodename nor servname provided, or not known\n",
            status: 255, failure: .hostNotFound),
        Case(
            stderr: "ssh: connect to host omarchy port 22: Connection refused\n", status: 255,
            failure: .connectionRefused),
        // sshd dropping the connection before it's ready (still starting after a wake, or too
        // many at once): refused, so a reconnect tries again.
        Case(
            stderr:
                "kex_exchange_identification: read: Connection reset by peer\r\nConnection reset by 192.168.1.20 port 22\r\n",
            status: 255, failure: .connectionRefused),
        Case(
            stderr:
                "kex_exchange_identification: Connection closed by remote host\r\nConnection closed by 192.168.1.20 port 22\r\n",
            status: 255, failure: .connectionRefused),
        // sshd never greeted within `ConnectTimeout`: a timeout, so retried even on the first
        // try, never taken for a mistyped host.
        Case(
            stderr:
                "Connection timed out during banner exchange\r\nConnection to 192.168.1.20 port 22 timed out\r\n",
            status: 255, failure: .unreachable),
        Case(
            stderr: "ssh: connect to host omarchy port 22: Operation timed out\n", status: 255,
            failure: .unreachable),
        Case(
            stderr: "ssh: connect to host omarchy port 22: No route to host\n", status: 255,
            failure: .unreachable),
        Case(
            stderr: "ssh: connect to host omarchy port 22: Network is unreachable\n", status: 255,
            failure: .unreachable),
        // The keepalives gave up (ServerAliveCountMax), e.g. mid-handshake.
        Case(stderr: "Timeout, server host not responding.\n", status: 255, failure: .unreachable),
        // The remote end's own message, not ssh's keepalive.
        Case(
            stderr: "compositor not responding\n", status: 255,
            failure: .other("compositor not responding")),
        Case(
            stderr: "bash: line 1: gliff-server: command not found\n", status: 127,
            failure: .serverNotInstalled),
        Case(stderr: "zsh:1: command not found: gliff-server\n", status: 127, failure: .serverNotInstalled),
        Case(stderr: "fish: Unknown command: gliff-server\n", status: 127, failure: .serverNotInstalled),
        Case(
            stderr: "ssh: connect to host omarchy port 22: Host is down\n", status: 255, failure: .unreachable
        ),
        Case(stderr: "something odd\nlast line\n", status: 1, failure: .other("last line")),
        Case(stderr: "", status: 1, failure: .other("ssh exited with status 1")),
        Case(stderr: "", status: -9, failure: .other("ssh was stopped by signal 9")),
    ]

    @Test(arguments: cases)
    func classifies(_ test: Case) {
        #expect(SSHErrorClassifier.classify(exitStatus: test.status, stderr: test.stderr) == test.failure)
    }

    /// A channel on the shared connection: ssh tries the master's socket, and without it tries
    /// a direct connection that `ProxyCommand=/usr/bin/false` ends at once.
    static let channelCases: [Case] = [
        Case(
            stderr: "channel 0: open failed: administratively prohibited: open failed\n", status: 255,
            failure: .channelRefused),
        Case(
            stderr: "mux_client_request_session: session request failed: Session open refused by peer\n",
            status: 255, failure: .channelRefused),
        Case(
            stderr: "Control socket connect(/x): Connection refused\n"
                + "kex_exchange_identification: Connection closed by remote host\n"
                + "Connection closed by UNKNOWN port 65535\n", status: 255, failure: .sharedConnectionLost),
        Case(
            stderr: "kex_exchange_identification: Connection closed by remote host\n"
                + "Connection closed by UNKNOWN port 65535\n", status: 255, failure: .sharedConnectionLost),
        Case(
            stderr: "mux_client_read_packet: read header failed: Broken pipe\n", status: 255,
            failure: .sharedConnectionLost),
        Case(
            stderr: "mux_client_request_session: read from master failed: Broken pipe\n", status: 255,
            failure: .sharedConnectionLost),
        Case(
            stderr: "bash: line 1: gliff-server: command not found\n", status: 127,
            failure: .serverNotInstalled),
    ]

    @Test(arguments: channelCases)
    func classifiesAChannel(_ test: Case) {
        let failure = SSHErrorClassifier.classifyChannel(exitStatus: test.status, stderr: test.stderr)
        #expect(failure == test.failure)
    }

    /// A ProxyJump host that forbids forwarding, or a stale ControlPath of the person's own, is
    /// not this app's shared connection.
    @Test func sharedConnectionWordsMeanNothingElsewhere() {
        let jump =
            "channel 0: open failed: administratively prohibited: open failed\n"
            + "stdio forwarding failed\nkex_exchange_identification: Connection closed by remote host\n"
        #expect(SSHErrorClassifier.classify(exitStatus: 255, stderr: jump) == .connectionRefused)
        let stale =
            "Control socket connect(/x): Connection refused\n"
            + "@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @\nHost key verification failed.\n"
        #expect(SSHErrorClassifier.classify(exitStatus: 255, stderr: stale) == .changedHostKey)
    }

    /// Network words from the remote program (not ssh, which exits 255) aren't ssh failures.
    @Test func remoteOutputIsNotMistakenForSSH() {
        #expect(
            SSHErrorClassifier.classify(exitStatus: 1, stderr: "gliff-server: Connection refused\n")
                == .other("gliff-server: Connection refused"))
    }

    /// The last line comes from the remote host: control characters go, and it is capped.
    @Test func otherLineIsCleanedAndCapped() {
        let escaped = SSHErrorClassifier.classify(exitStatus: 1, stderr: "\u{1b}[31mred\u{1b}[0m\n")
        #expect(escaped == .other("[31mred[0m"))
        // Bidi overrides and other format characters could make the text read differently.
        #expect(SSHErrorClassifier.displayable("evil\u{202E}txt.exe\u{2066}x") == "eviltxt.exex")
        let long = SSHErrorClassifier.classify(exitStatus: 1, stderr: String(repeating: "x", count: 10_000))
        #expect(long == .other(String(repeating: "x", count: 200) + "…"))
    }

    /// Line and paragraph separators would break one remote line into several.
    @Test func separatorsAreRemoved() {
        #expect(SSHErrorClassifier.displayable("a\u{2028}b\u{2029}c") == "abc")
    }

    /// One Character can hold any number of combining marks: the cap counts scalars.
    @Test func combiningMarksCountTowardTheCap() {
        let flood = "A" + String(repeating: "\u{301}", count: 5000)
        #expect(SSHErrorClassifier.displayable(flood).unicodeScalars.count <= 201)
    }

    @Test func everyFailureHasAMessage() {
        let all: [ConnectFailure] = [
            .unknownHostKey, .changedHostKey, .permissionDenied, .agentRefused, .hostNotFound,
            .connectionRefused, .unreachable, .serverNotInstalled,
        ]
        for failure in all { #expect(!failure.message.isEmpty) }
        #expect(ConnectFailure.other("boom").message == "boom")
        #expect(ConnectFailure.hostNotFound.message == "That host name couldn't be found.")
        // Plain text: SwiftUI shows a String verbatim, so no Markdown or placeholders.
        for failure in all { #expect(!failure.message.contains("`") && !failure.message.contains("<")) }
    }
}
