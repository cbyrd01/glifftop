import Foundation
import GliffAskpass
import Synchronization
import Testing

/// `AskpassHelper.run` against a listener the test plays, with its stdout a pipe.
struct AskpassHelperTests {
    static let token = [UInt8](0..<32)
    static var tokenHex: String { AskpassWire.tokenText(token) }

    /// Runs the helper with `prompt` while `serve` plays the app on the accepted socket; returns
    /// the helper's status and stdout, what `serve` returned, and whether it ended its ssh.
    static func run<T: Sendable>(
        prompt: String, environment extra: [String: String] = [:], withSocket: Bool = true,
        closedOutput: Bool = false, serve: @escaping @Sendable (Int32) -> T
    ) async throws -> (status: Int32, output: [UInt8], served: T?, took: Duration, endedSSH: Bool) {
        let listener = try TestListener()
        defer { listener.close() }
        var environment = [AskpassWire.tokenVariable: tokenHex]
        if withSocket { environment[AskpassWire.socketVariable] = listener.path }
        environment.merge(extra) { $1 }
        let output = Pipe()
        let writer = output.fileHandleForWriting.fileDescriptor
        let served = Task.detached { () -> T? in
            guard let client = listener.accept() else { return nil }
            defer { Darwin.close(client) }
            return serve(client)
        }
        if closedOutput { try output.fileHandleForReading.close() }
        let start = ContinuousClock.now
        let ended = Mutex(false)
        let status = await Task.detached { [environment] in
            AskpassHelper.run(
                arguments: ["glifftop-askpass", prompt], environment: environment, output: writer,
                endSSH: { ended.withLock { $0 = true } })
        }.value
        let took = ContinuousClock.now - start
        // A helper that never connected leaves `accept` waiting: stop listening.
        listener.close()
        try output.fileHandleForWriting.close()
        let bytes = closedOutput ? [] : [UInt8](output.fileHandleForReading.readDataToEndOfFile())
        return (status, bytes, await served.value, took, ended.withLock { $0 })
    }

    /// Runs the helper against `path`, where nothing answers: its status, and whether it ended
    /// its ssh.
    static func run(at path: String) -> (status: Int32, endedSSH: Bool) {
        let ended = Mutex(false)
        let status = AskpassHelper.run(
            arguments: ["glifftop-askpass", "p"],
            environment: [AskpassWire.tokenVariable: tokenHex, AskpassWire.socketVariable: path],
            output: -1, endSSH: { ended.withLock { $0 = true } })
        return (status, ended.withLock { $0 })
    }

    static func readRequest(_ socket: Int32) -> AskpassRequest? {
        guard let header = TestListener.read(socket, count: AskpassRequest.headerLength),
            let length = try? AskpassRequest.textLength(header: header),
            let text = TestListener.read(socket, count: length)
        else { return nil }
        return try? AskpassRequest.decode(header + text)
    }

    static func reply(_ socket: Int32, _ answer: String) {
        let bytes = Array(answer.utf8)
        TestListener.write(socket, (try? AskpassReply.header(.answer, length: bytes.count) + bytes) ?? [])
    }

    @Test func theHelperWritesTheAnswerAndANewline() async throws {
        let result = try await Self.run(prompt: "person@omarchy's password: ") { socket in
            _ = Self.readRequest(socket)
            Self.reply(socket, "secret")
        }
        #expect(result.status == 0)
        #expect(result.output == Array("secret\n".utf8))
        #expect(!result.endedSSH)
    }

    @Test func theHelperSendsTheTokenAndPrompt() async throws {
        let result = try await Self.run(prompt: "person@omarchy's password: ") { socket in
            defer { Self.reply(socket, "x") }
            return Self.readRequest(socket)
        }
        #expect(
            result.served
                == AskpassRequest(token: Self.token, kind: .ask, text: "person@omarchy's password: "))
    }

    @Test func aRefusalWritesNothingAndFails() async throws {
        let result = try await Self.run(prompt: "p") { socket in
            _ = Self.readRequest(socket)
            TestListener.write(socket, (try? AskpassReply.header(.refuse, length: 0)) ?? [])
        }
        #expect(result.status == 1)
        #expect(result.output.isEmpty)
        #expect(!result.endedSSH)
    }

    /// The app went away with the question open (a crash, Force Quit): ssh would read the
    /// helper's failure as an empty answer and send it, so the helper ends ssh first.
    @Test func aSocketClosedWithoutAReplyEndsSSH() async throws {
        let result = try await Self.run(prompt: "p") { socket in _ = Self.readRequest(socket) }
        #expect(result.status == 1)
        #expect(result.output.isEmpty)
        #expect(result.endedSSH)
    }

    /// The app went away partway through its reply: the helper ends ssh, as for no reply.
    @Test(arguments: [
        [AskpassWire.version],
        [AskpassWire.version, AskpassReply.Status.answer.rawValue, 0, 6] + Array("sec".utf8),
    ])
    func aReplyCutShortEndsSSH(_ sent: [UInt8]) async throws {
        let result = try await Self.run(prompt: "p") { socket in
            _ = Self.readRequest(socket)
            TestListener.write(socket, sent)
        }
        #expect(result.status == 1)
        #expect(result.output.isEmpty)
        #expect(result.endedSSH)
    }

    /// A socket left by an app that went away refuses the connection: the helper ends ssh.
    @Test func aSocketLeftByAGoneAppEndsSSH() throws {
        let directory = "/tmp/gat-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let listener = try #require(AskpassSocket.listening(at: directory + "/b"))
        close(listener)
        let result = Self.run(at: directory + "/b")
        #expect(result.status == 1)
        #expect(result.endedSSH)
    }

    /// The bridge removes its socket on purpose (the master ready, or being ended): the helper
    /// fails without ending ssh.
    @Test func aRemovedSocketLeavesSSHAlone() {
        let result = Self.run(at: "/tmp/gat-\(UUID().uuidString.prefix(8))/b")
        #expect(result.status == 1)
        #expect(!result.endedSSH)
    }

    @Test(arguments: ["line\nbreak", "carriage\rreturn", "nul\u{0}byte"])
    func anAnswerWithALineBreakOrNULIsRefused(_ answer: String) async throws {
        let result = try await Self.run(prompt: "p") { socket in
            _ = Self.readRequest(socket)
            Self.reply(socket, answer)
        }
        #expect(result.status == 1)
        #expect(result.output.isEmpty)
    }

    @Test func aClosedOutputFails() async throws {
        let result = try await Self.run(prompt: "p", closedOutput: true) { socket in
            _ = Self.readRequest(socket)
            Self.reply(socket, "secret")
        }
        #expect(result.status == 1)
    }

    @Test func aMalformedTokenFailsWithoutConnecting() async throws {
        let result = try await Self.run(
            prompt: "p", environment: [AskpassWire.tokenVariable: "zz"]
        ) { _ in () }
        #expect(result.status == 1)
        #expect(result.served == nil)
    }

    @Test func noSocketVariableFails() async throws {
        let result = try await Self.run(prompt: "p", withSocket: false) { _ in () }
        #expect(result.status == 1)
        #expect(result.output.isEmpty)
    }

    @Test func aNoticeWaitsUntilTheSocketCloses() async throws {
        let result = try await Self.run(
            prompt: "Confirm user presence", environment: ["SSH_ASKPASS_PROMPT": "none"]
        ) {
            socket in
            let request = Self.readRequest(socket)
            Thread.sleep(forTimeInterval: 0.3)
            return request?.kind
        }
        #expect(result.took >= .milliseconds(300))
        #expect(result.served == .notice)
        #expect(result.status == 1)
        #expect(result.output.isEmpty)
        #expect(!result.endedSSH)
    }

    @Test func aLongPromptIsCutToTheLimit() async throws {
        let long = String(repeating: "é", count: 9 * 1024 / 2)
        let result = try await Self.run(prompt: long) { socket in
            defer { Self.reply(socket, "x") }
            return Self.readRequest(socket)?.text
        }
        let text = try #require(result.served ?? nil)
        #expect(text.utf8.count <= AskpassWire.textLimit)
        #expect(text.utf8.count > AskpassWire.textLimit - 2)
        #expect(text.allSatisfy { $0 == "é" })
    }
}
