import Testing

@testable import GliffTransport

/// The master's answers to `-O forward` and `-O cancel`, as OpenSSH 10.5p1 writes them (each
/// failure a second line after the first, and `\r\n`).
struct SSHForwardClassifierTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let request: String
        let status: Int32
        let stderr: String
        let expected: ForwardError?
        var testDescription: String { "\(request) \(status) \(stderr.prefix(30))" }
    }

    static let cases: [Case] = [
        Case(request: "forward", status: 0, stderr: "", expected: nil),
        Case(
            request: "forward", status: 255,
            stderr: "mux_client_forward: forwarding request failed: Port forwarding failed\r\n"
                + "muxclient: master forward request failed\r\n",
            expected: .localPortInUse),
        Case(
            request: "forward", status: 255,
            stderr: "Control socket connect(/s/1-1): No such file or directory\n", expected: .connectionLost),
        Case(
            request: "forward", status: 255, stderr: "Bad local forwarding specification '1:2'\n",
            expected: .failed),
        Case(request: "forward", status: 1, stderr: "", expected: .failed),
        Case(request: "cancel", status: 0, stderr: "", expected: nil),
        Case(
            request: "cancel", status: 0,
            stderr: "mux_client_forward: forwarding request failed: port not forwarded\r\n"
                + "muxclient: master cancel forward request failed\r\n",
            expected: nil),
        Case(
            request: "cancel", status: 255,
            stderr: "Control socket connect(/s/1-1): Connection refused\n", expected: .connectionLost),
        Case(
            request: "cancel", status: 0,
            stderr: "mux_client_forward: forwarding request failed: port not found\r\n"
                + "muxclient: master cancel forward request failed\r\n",
            expected: .failed),
        Case(request: "cancel", status: 255, stderr: "", expected: .failed),
        Case(
            request: "cancel", status: 255, stderr: "read from master failed: Broken pipe\r\n",
            expected: .failed),
        Case(
            request: "cancel", status: 255,
            stderr: "Control socket connect(/x): No such file or directory\r\n", expected: .connectionLost),
        Case(
            request: "forward", status: 255, stderr: "read from master failed: Broken pipe\r\n",
            expected: .failed),
        Case(request: "cancel", status: 0, stderr: "something else\n", expected: .failed),
        Case(request: "cancel", status: 1, stderr: "", expected: .failed),
    ]

    @Test(arguments: cases) func theClassifierReadsEachLine(_ c: Case) {
        let result =
            c.request == "forward"
            ? SSHForwardClassifier.forward(status: c.status, stderr: c.stderr)
            : SSHForwardClassifier.cancel(status: c.status, stderr: c.stderr)
        switch (result, c.expected) {
        case (.success, nil): break
        case (.failure(let error), let expected?): #expect(error == expected)
        default: Issue.record("got \(result), expected \(String(describing: c.expected))")
        }
    }
}
