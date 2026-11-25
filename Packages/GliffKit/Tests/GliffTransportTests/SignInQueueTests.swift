import Testing

@testable import GliffTransport

/// A window's questions, shown one at a time.
@MainActor @Suite struct SignInQueueTests {
    let queue = SignInQueue()
    static let password = SignInQuestion.password(host: "omarchy", account: "me@omarchy", text: "pw: ")
    static let hostKey = SignInQuestion.hostKey(
        HostKeyQuestion(host: "omarchy", keyType: "ED25519", fingerprint: "SHA256:x", details: []))
    static let passphrase = SignInQuestion.passphrase(
        host: "omarchy", text: "Enter passphrase for key '/k': ")

    static func kind(_ answer: consuming SignInAnswer) -> String {
        switch consume answer {
        case .allow: "allow"
        case .deny: "deny"
        case .secret(let secret): "secret \(secret.count)"
        case .cancel: "cancel"
        }
    }

    func asking(_ question: SignInQuestion) -> Task<String, Never> {
        Task { [queue] in Self.kind(await queue.ask(question)) }
    }

    func shown(_ question: SignInQuestion?) async -> Bool {
        for _ in 0..<200 {
            if queue.current?.question == question { return true }
            await Task.yield()
        }
        return false
    }

    @Test func theQuestionShownIsAnswered() async {
        let asked = asking(Self.password)
        #expect(await shown(Self.password))
        queue.answer(.secret(SignInSecret(copying: "pw")), for: queue.current?.id ?? -1)
        #expect(await asked.value == "secret 2")
        #expect(queue.current == nil)
    }

    @Test func aSecondQuestionWaitsItsTurn() async {
        let first = asking(Self.password)
        #expect(await shown(Self.password))
        let second = asking(Self.passphrase)
        for _ in 0..<20 { await Task.yield() }
        #expect(queue.current?.question == Self.password)
        queue.answer(.cancel, for: queue.current?.id ?? -1)
        #expect(await first.value == "cancel")
        #expect(await shown(Self.passphrase))
        queue.answer(.secret(SignInSecret(copying: "key")), for: queue.current?.id ?? -1)
        #expect(await second.value == "secret 3")
    }

    @Test func aCancelledAskIsDismissed() async {
        let asked = asking(Self.password)
        #expect(await shown(Self.password))
        asked.cancel()
        #expect(await asked.value == "cancel")
        #expect(await shown(nil))
    }

    @Test func aCancelledWaitingAskLeavesTheShownOne() async {
        let first = asking(Self.password)
        #expect(await shown(Self.password))
        let second = asking(Self.passphrase)
        for _ in 0..<20 { await Task.yield() }
        second.cancel()
        #expect(await second.value == "cancel")
        #expect(queue.current?.question == Self.password)
        queue.answer(.allow, for: queue.current?.id ?? -1)
        #expect(await first.value == "allow")
        #expect(queue.current == nil)
    }

    @Test func anAskAlreadyCancelledIsNeverShown() async {
        var changes = 0
        queue.changed = { changes += 1 }
        let asked = Task { [queue] in
            withUnsafeCurrentTask { $0?.cancel() }
            return Self.kind(await queue.ask(Self.password))
        }
        #expect(await asked.value == "cancel")
        for _ in 0..<20 { await Task.yield() }
        #expect(changes == 0)
    }

    @Test func anAnswerWithNothingShownIsDropped() {
        queue.answer(.allow, for: 0)
        #expect(queue.current == nil)
    }

    /// A second click, or Return heard twice, lands after its question has gone: it never
    /// answers the next one.
    @Test func anAnswerForAQuestionGoneIsDropped() async {
        let first = asking(Self.hostKey)
        #expect(await shown(Self.hostKey))
        let shownID = queue.current?.id ?? -1
        let second = asking(Self.passphrase)
        for _ in 0..<20 { await Task.yield() }
        queue.answer(.allow, for: shownID)
        #expect(await first.value == "allow")
        #expect(await shown(Self.passphrase))
        queue.answer(.allow, for: shownID)
        for _ in 0..<20 { await Task.yield() }
        #expect(queue.current?.question == Self.passphrase)
        queue.answer(.cancel, for: queue.current?.id ?? -1)
        #expect(await second.value == "cancel")
    }

    /// Each question shown, and its going, is reported once.
    @Test func eachChangeIsReported() async {
        var seen: [SignInQuestion?] = []
        queue.changed = { [queue] in seen.append(queue.current?.question) }
        let asked = asking(Self.password)
        #expect(await shown(Self.password))
        queue.answer(.deny, for: queue.current?.id ?? -1)
        _ = await asked.value
        #expect(seen == [Self.password, nil])
    }
}
