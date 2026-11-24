#if os(macOS)
    import Foundation
    import GliffAskpass
    import Synchronization
    import Testing

    @testable import GliffTransport

    /// The bridge against the real helper logic (`AskpassHelper.run` on a thread) or raw frames.
    /// The peer check is a stand-in: `AskpassPeer` needs a real ssh parent (the live check).
    @Suite(.timeLimit(.minutes(1))) final class AskpassBridgeTests: Sendable {
        struct Peer: AskpassPeerCheck {
            let accepting: Bool
            func accepts(_ socket: Int32) -> Bool { accepting }
        }

        /// What `ask` and `end` saw, in order.
        final class Record: Sendable {
            let events = Mutex<[String]>([])
            let questions = Mutex<[SignInQuestion]>([])
            func add(_ event: String) { events.withLock { $0.append(event) } }
            var asked: Int { questions.withLock(\.count) }
        }

        static let fingerprint = "SHA256:ASFf47m3ZeIPySUT2MoJMWo0cEUXbpBbhcPi49mvyF8"
        static let hostKey =
            "The authenticity of host 'omarchy (2001:db8::1)' can't be established.\n"
            + "ED25519 key fingerprint is: \(fingerprint)\n"
            + "Are you sure you want to continue connecting (yes/no/[fingerprint])? "

        let path = "/tmp/abt-\(UUID().uuidString.prefix(8))"
        let token = AskpassBridge.newToken()
        let record = Record()

        deinit { unlink(path) }

        func bridge(
            accepting: Bool = true, ioLimit: Duration = .seconds(10),
            ask: @escaping @Sendable (SignInQuestion) async -> SignInAnswer
        ) throws -> AskpassBridge {
            let record = record
            let bridge = AskpassBridge(
                path: path, token: token, destination: "omarchy", names: [], peer: Peer(accepting: accepting),
                ask: { question in
                    record.questions.withLock { $0.append(question) }
                    return await ask(question)
                },
                end: {
                    // Ending a master takes a moment: the helper must not answer meanwhile.
                    try? await Task.sleep(for: .milliseconds(200))
                    record.add("end")
                }, ioLimit: ioLimit)
            try bridge.start()
            return bridge
        }

        /// Runs the helper on its own thread: its exit status and what it wrote to stdout.
        func helper(_ prompt: String, token: [UInt8]? = nil, notice: Bool = false) async -> (Int32, String) {
            var environment = [
                AskpassWire.socketVariable: path,
                AskpassWire.tokenVariable: (token ?? self.token).map { String(format: "%02x", $0) }.joined(),
            ]
            if notice { environment["SSH_ASKPASS_PROMPT"] = "none" }
            let (record, variables) = (record, environment)
            return await withCheckedContinuation { result in
                Thread.detachNewThread {
                    var pipe: [Int32] = [0, 0]
                    _ = Darwin.pipe(&pipe)
                    let status = AskpassHelper.run(
                        arguments: ["glifftop-askpass", prompt], environment: variables, output: pipe[1])
                    record.add("helper")
                    close(pipe[1])
                    var bytes: [UInt8] = []
                    var byte: UInt8 = 0
                    while read(pipe[0], &byte, 1) == 1 { bytes.append(byte) }
                    close(pipe[0])
                    result.resume(returning: (status, String(decoding: bytes, as: UTF8.self)))
                }
            }
        }

        /// A raw client: connected, with `bytes` sent.
        func connect(sending bytes: [UInt8]) throws -> Int32 {
            let socket = try #require(AskpassSocket.connect(to: path))
            _ = bytes.withUnsafeBytes { AskpassSocket.write(socket, $0) }
            return socket
        }

        /// Whether the bridge closes `socket` (a read sees its end) within `limit`.
        func closes(_ socket: Int32, within limit: Duration) async -> Bool {
            var timeout = timeval(tv_sec: Int(limit.components.seconds), tv_usec: 300_000)
            setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            return await withCheckedContinuation { result in
                Thread.detachNewThread {
                    var byte: UInt8 = 0
                    result.resume(returning: read(socket, &byte, 1) == 0)
                }
            }
        }

        @Test func aPasswordIsAskedAndAnswered() async throws {
            let bridge = try bridge { _ in .secret(SignInSecret(copying: "pw")) }
            let (status, output) = await helper("person@omarchy's password: ")
            #expect(status == 0 && output == "pw\n")
            #expect(
                record.questions.withLock { $0 }
                    == [
                        .password(
                            host: "omarchy", account: "person@omarchy", text: "person@omarchy's password: ")
                    ])
            #expect(bridge.outcome == nil)
            bridge.revoke()
        }

        @Test func allowAnswersWithTheFingerprint() async throws {
            let bridge = try bridge { _ in .allow }
            let (status, output) = await helper(Self.hostKey)
            #expect(status == 0 && output == Self.fingerprint + "\n")
            bridge.revoke()
        }

        @Test func denyAnswersNo() async throws {
            let bridge = try bridge { _ in .deny }
            let (status, output) = await helper(Self.hostKey)
            #expect(status == 0 && output == "no\n")
            #expect(bridge.outcome == .denied)
            bridge.revoke()
        }

        @Test func cancelEndsTheMasterBeforeTheHelperAnswers() async throws {
            let bridge = try bridge { _ in .cancel }
            let (status, output) = await helper("person@omarchy's password: ")
            #expect(status == 1 && output.isEmpty)
            #expect(record.events.withLock { $0 } == ["end", "helper"])
            #expect(bridge.outcome == .cancelled)
            bridge.revoke()
        }

        @Test func aWrongTokenIsClosedUnanswered() async throws {
            let bridge = try bridge { _ in .secret(SignInSecret(copying: "pw")) }
            let (status, output) = await helper(
                "person@omarchy's password: ", token: AskpassBridge.newToken())
            #expect(status == 1 && output.isEmpty && record.asked == 0)
            #expect(bridge.outcome == .cancelled && record.events.withLock { $0.first } == "end")
            bridge.revoke()
        }

        @Test func aRefusedPeerIsClosedUnanswered() async throws {
            let bridge = try bridge(accepting: false) { _ in .secret(SignInSecret(copying: "pw")) }
            let (status, output) = await helper("person@omarchy's password: ")
            #expect(status == 1 && output.isEmpty && record.asked == 0)
            #expect(bridge.outcome == .cancelled)
            bridge.revoke()
        }

        @Test func unknownTextCancels() async throws {
            let bridge = try bridge { _ in .secret(SignInSecret(copying: "pw")) }
            let (status, _) = await helper("Something else: ")
            #expect(status == 1 && record.asked == 0 && bridge.outcome == .cancelled)
            bridge.revoke()
        }

        @Test func aSecretWithALineBreakCancels() async throws {
            let bridge = try bridge { _ in .secret(SignInSecret(copying: "p\nw")) }
            let (status, output) = await helper("person@omarchy's password: ")
            #expect(status == 1 && output.isEmpty)
            #expect(record.events.withLock { $0 } == ["end", "helper"] && bridge.outcome == .cancelled)
            bridge.revoke()
        }

        @Test func theEleventhQuestionIsTooMany() async throws {
            let bridge = try bridge { _ in .secret(SignInSecret(copying: "pw")) }
            for _ in 0..<10 {
                let (status, _) = await helper("person@omarchy's password: ")
                #expect(status == 0)
            }
            let (status, _) = await helper("person@omarchy's password: ")
            #expect(status == 1 && record.asked == 10 && bridge.outcome == .tooMany)
            #expect(record.events.withLock { $0.contains("end") })
            bridge.revoke()
        }

        @Test func afterAnOutcomeEveryQuestionIsRefused() async throws {
            let bridge = try bridge { _ in .cancel }
            _ = await helper("person@omarchy's password: ")
            let (status, _) = await helper("person@omarchy's password: ")
            #expect(status == 1 && record.asked == 1)
            bridge.revoke()
        }

        @Test func aRevokedTokenAnswersNothing() async throws {
            let bridge = try bridge { _ in .secret(SignInSecret(copying: "pw")) }
            bridge.revoke()
            let (status, _) = await helper("person@omarchy's password: ")
            #expect(status == 1 && record.asked == 0)
            #expect(!FileManager.default.fileExists(atPath: path))
        }

        @Test func aSilentHelperTimesOut() async throws {
            let bridge = try bridge(ioLimit: .milliseconds(100)) { _ in .allow }
            let socket = try connect(sending: [])
            defer { close(socket) }
            #expect(await closes(socket, within: .seconds(2)))
            #expect(record.asked == 0)
            bridge.revoke()
        }

        @Test func questionOpenIsTrueWhileAsking() async throws {
            let (opened, open) = AsyncStream.makeStream(of: Void.self)
            let (released, release) = AsyncStream.makeStream(of: Void.self)
            let bridge = try bridge { _ in
                open.yield()
                for await _ in released { break }
                return .secret(SignInSecret(copying: "pw"))
            }
            #expect(!bridge.questionOpen)
            async let answered = helper("person@omarchy's password: ")
            for await _ in opened { break }
            #expect(bridge.questionOpen)
            release.yield()
            #expect(await answered.0 == 0)
            #expect(!bridge.questionOpen)
            bridge.revoke()
        }

        /// Revoking ends an open question: ssh's helper gets no answer, and the master is ended.
        @Test func revokeEndsAnOpenQuestion() async throws {
            let (cancelled, cancel) = AsyncStream.makeStream(of: Bool.self)
            let bridge = try bridge { _ in
                try? await Task.sleep(for: .seconds(30))
                cancel.yield(Task.isCancelled)
                return .cancel
            }
            async let answered = helper("person@omarchy's password: ")
            while !bridge.questionOpen { try await Task.sleep(for: .milliseconds(10)) }
            bridge.revoke()
            var sawCancel = false
            for await value in cancelled {
                sawCancel = value
                break
            }
            #expect(sawCancel)
            #expect(await answered.0 == 1)
            #expect(record.events.withLock { $0 } == ["end", "helper"])
        }

        /// ssh waits for an answer to a question that isn't a notice: its helper going away
        /// unanswered must end the master, or ssh would send an empty answer.
        @Test func aClosedHelperOfAQuestionEndsTheMaster() async throws {
            let bridge = try bridge { _ in
                try? await Task.sleep(for: .seconds(30))
                return .cancel
            }
            let request = AskpassRequest(token: token, kind: .ask, text: "person@omarchy's password: ")
                .encoded()
            let socket = try connect(sending: request)
            while !bridge.questionOpen { try await Task.sleep(for: .milliseconds(10)) }
            close(socket)
            while !record.events.withLock({ $0.contains("end") }) {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(bridge.outcome == .cancelled)
            bridge.revoke()
        }

        /// The kernel reports the helper's resolved path, so the expected one is resolved too.
        @Test func thePeersHelperPathIsResolved() throws {
            let link = "/tmp/abt-link-\(UUID().uuidString.prefix(8))"
            try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "/usr/bin/true")
            defer { unlink(link) }
            #expect(AskpassPeer(helper: link, masterPID: { nil }).helper == "/usr/bin/true")
        }

        @Test func aClosedHelperCancelsItsQuestion() async throws {
            let (cancelled, cancel) = AsyncStream.makeStream(of: Bool.self)
            let bridge = try bridge { _ in
                try? await Task.sleep(for: .seconds(30))
                cancel.yield(Task.isCancelled)
                return .cancel
            }
            let request = AskpassRequest(token: token, kind: .notice, text: "Confirm user presence").encoded()
            let socket = try connect(sending: request)
            while !bridge.questionOpen { try await Task.sleep(for: .milliseconds(10)) }
            close(socket)
            var sawCancel = false
            for await value in cancelled {
                sawCancel = value
                break
            }
            #expect(sawCancel)
            while bridge.questionOpen { try await Task.sleep(for: .milliseconds(10)) }
            #expect(bridge.outcome == nil && !record.events.withLock { $0.contains("end") })
            bridge.revoke()
        }
    }
#endif
