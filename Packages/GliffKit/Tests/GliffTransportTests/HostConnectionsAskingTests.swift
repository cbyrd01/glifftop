import GliffTestSupport
import Synchronization
import Testing

@testable import GliffTransport

/// Which waiting window a shared open's sign-in questions go to.
@Suite struct HostConnectionsAskingTests {
    let clock = ManualClock()
    let opener = FakeOpener()
    let hosts: HostConnections

    init() { hosts = HostConnections(open: opener.open, clock: clock) }

    static let password = SignInQuestion.password(host: "omarchy", account: "person@omarchy", text: "pw? ")
    static let hostKey = SignInQuestion.hostKey(
        HostKeyQuestion(host: "omarchy", keyType: "ED25519", fingerprint: "SHA256:x", details: []))

    /// A window: records its questions and answers each with `answer` (which may wait until
    /// its task is cancelled).
    final class Asker: SignInAsker {
        let asked = Mutex<[SignInQuestion]>([])
        let answer: @Sendable () async -> SignInAnswer
        init(_ answer: @escaping @Sendable () async -> SignInAnswer) { self.answer = answer }
        var questions: [SignInQuestion] { asked.withLock { $0 } }
        func ask(_ question: SignInQuestion) async -> SignInAnswer {
            asked.withLock { $0.append(question) }
            return await answer()
        }
    }

    static func secret() -> Asker { Asker { .secret(SignInSecret(copying: "pw")) } }
    /// Never answers: waits until its task is cancelled, then cancels.
    static func waiting() -> Asker {
        Asker {
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
            return .cancel
        }
    }

    func omarchy() throws -> SSHTarget { try SSHTarget("omarchy") }

    func failure(_ leasing: () async throws -> HostLease) async -> ConnectFailure? {
        do {
            _ = try await leasing()
            return nil
        } catch {
            guard case .exited(_, let failure) = error as? TransportError else { return nil }
            return failure
        }
    }

    @Test func theOpenersAskerIsAsked() async throws {
        opener.ask([Self.password])
        let a = Self.secret()
        _ = try await hosts.lease(for: omarchy(), fresh: true, asker: a)
        #expect(a.questions == [Self.password])
        #expect(opener.answers == ["secret"])
    }

    @Test func aLeaseWithoutAnAskerOpensWithoutQuestions() async throws {
        _ = try await hosts.lease(for: omarchy())
        #expect(opener.askedWith == [false])
    }

    @Test func aClosedAskerHandsTheQuestionOn() async throws {
        opener.ask([Self.password])
        let (a, b) = (Self.waiting(), Self.secret())
        let target = try omarchy()
        let first = Task { try await hosts.lease(for: target, fresh: true, asker: a) }
        #expect(await eventually { a.questions.count == 1 })
        let second = Task { try await hosts.lease(for: target, asker: b) }
        #expect(await eventually { await hosts.waiterCount(for: target) == 2 })
        first.cancel()
        _ = try await second.value
        #expect(b.questions == [Self.password])
        #expect(opener.answers == ["secret"])
    }

    @Test func theLastAskerLeavingCancels() async throws {
        opener.ask([Self.password])
        let a = Self.waiting()
        let target = try omarchy()
        let first = Task { try await hosts.lease(for: target, fresh: true, asker: a) }
        #expect(await eventually { a.questions.count == 1 })
        first.cancel()
        #expect(await clock.waitForSleepers(2))
        clock.advance(by: .seconds(1))
        #expect(await eventually { opener.answers == ["cancel"] })
        // A cancel for want of anyone to ask isn't the person's, so it isn't remembered.
        #expect(await eventually { await hosts.hostCount == 0 })
        opener.ask([])
        _ = try await hosts.lease(for: target)
        #expect(opener.calls == 2)
    }

    /// A listing's sign-in, its window gone as the session it chose starts: the session takes
    /// the question within the open's grace.
    @Test func aQuestionWaitsForTheNextWindow() async throws {
        opener.ask([Self.password])
        let (a, b) = (Self.waiting(), Self.secret())
        let target = try omarchy()
        let first = Task { try await hosts.lease(for: target, fresh: true, asker: a) }
        #expect(await eventually { a.questions.count == 1 })
        first.cancel()
        #expect(await clock.waitForSleepers(2))
        _ = try await hosts.lease(for: target, asker: b)
        #expect(b.questions == [Self.password])
        #expect(opener.answers == ["secret"])
    }

    /// A window closing cancels its lease and dismisses its question: that Cancel hands the
    /// question on, whichever reaches the connections first.
    @Test func aClosingWindowsCancelHandsTheQuestionOn() async throws {
        opener.ask([Self.password])
        let leasing = Mutex<Task<HostLease, any Error>?>(nil)
        let a = Asker {
            leasing.withLock { $0 }?.cancel()
            return .cancel
        }
        let gate = CloseGate()
        let b = Asker {
            await gate.pass()
            return .secret(SignInSecret(copying: "pw"))
        }
        let target = try omarchy()
        opener.hold()
        let first = Task { try await hosts.lease(for: target, fresh: true, asker: a) }
        leasing.withLock { $0 = first }
        #expect(await eventually { opener.waitingCount == 1 })
        let second = Task { try await hosts.lease(for: target, asker: b) }
        #expect(await eventually { await hosts.waiterCount(for: target) == 2 })
        opener.release()
        #expect(await eventually { b.questions.count == 1 })
        gate.open()
        _ = try await second.value
        #expect(opener.answers == ["secret"])
    }

    @Test func cancelFailsEveryWaiter() async throws {
        opener.ask([Self.password])
        let gate = CloseGate()
        let a = Asker {
            await gate.pass()
            return .cancel
        }
        let target = try omarchy()
        async let first = failure { try await hosts.lease(for: target, fresh: true, asker: a) }
        #expect(await eventually { a.questions.count == 1 })
        async let second = failure { try await hosts.lease(for: target, asker: Self.secret()) }
        #expect(await eventually { await hosts.waiterCount(for: target) == 2 })
        gate.open()
        #expect(await first == .signInCancelled)
        #expect(await second == .signInCancelled)
    }

    /// ssh ending a question itself (a notice, once the key is touched) isn't a cancel for want
    /// of a window: the open's failure is remembered.
    @Test func aQuestionSSHEndsLeavesTheFailureRemembered() async throws {
        opener.ask([.notice(host: "omarchy", text: "Confirm user presence for key ED25519-SK")])
        opener.detachQuestions(then: .exited(status: 255, failure: .permissionDenied))
        let a = Self.waiting()
        let target = try omarchy()
        async let first = failure { try await hosts.lease(for: target, fresh: true, asker: a) }
        #expect(await eventually { a.questions.count == 1 })
        opener.release()
        #expect(await first == .permissionDenied)
        opener.ask([])
        #expect(await failure { try await hosts.lease(for: target) } == .permissionDenied)
        #expect(opener.calls == 1)
    }

    /// The open ending while its question waits for a window frees the question.
    @Test func anOpenEndingFreesAQuestionWaitingForAWindow() async throws {
        opener.ask([Self.password])
        opener.detachQuestions(then: .exited(status: 255, failure: .unreachable))
        let a = Self.waiting()
        let target = try omarchy()
        let first = Task { try await hosts.lease(for: target, fresh: true, asker: a) }
        #expect(await eventually { a.questions.count == 1 })
        first.cancel()
        #expect(await clock.waitForSleepers(2))
        opener.release()
        #expect(await eventually { await hosts.hostCount == 0 })
    }

    /// A question nobody could be shown would come again at once: its failure is remembered.
    @Test func anUnknownQuestionIsRemembered() async throws {
        opener.failNext(.exited(status: 255, failure: .unknownQuestion))
        let target = try omarchy()
        #expect(
            await failure { try await hosts.lease(for: target, asker: Self.secret()) } == .unknownQuestion)
        #expect(await failure { try await hosts.lease(for: target) } == .unknownQuestion)
        #expect(opener.calls == 1)
    }

    @Test func aReconnectNeverAsksAboutAHostKey() async throws {
        opener.ask([Self.hostKey])
        let a = Self.secret()
        let failure = await failure { try await hosts.lease(for: omarchy(), asker: a) }
        #expect(failure == .hostKeyUnchecked)
        #expect(a.questions.isEmpty)
    }

    @Test func aReconnectNeverConfirmsAKeyWarning() async throws {
        opener.ask([
            .confirm(host: "omarchy", text: "Are you sure you want to continue connecting (yes/no)? ")
        ])
        let a = Self.secret()
        let failure = await failure { try await hosts.lease(for: omarchy(), asker: a) }
        #expect(failure == .hostKeyUnchecked)
        #expect(a.questions.isEmpty)
    }

    @Test func aReconnectAsksForAPassword() async throws {
        opener.ask([Self.password])
        let a = Self.secret()
        _ = try await hosts.lease(for: omarchy(), asker: a)
        #expect(a.questions == [Self.password])
    }

    @Test func aFreshWaiterIsAskedAboutTheHostKey() async throws {
        opener.ask([Self.hostKey])
        opener.hold()
        let (a, b) = (Asker { .allow }, Asker { .allow })
        let target = try omarchy()
        async let first = hosts.lease(for: target, asker: a)
        #expect(await eventually { opener.waitingCount == 1 })
        async let second = hosts.lease(for: target, fresh: true, asker: b)
        #expect(await eventually { await hosts.waiterCount(for: target) == 2 })
        opener.release()
        _ = try await (first, second)
        #expect(a.questions.isEmpty)
        #expect(b.questions == [Self.hostKey])
    }

    @Test func aCancelledSignInIsRemembered() async throws {
        opener.ask([Self.password])
        let target = try omarchy()
        let cancelled = await failure {
            try await hosts.lease(for: target, fresh: true, asker: Asker { .cancel })
        }
        #expect(cancelled == .signInCancelled)
        #expect(await failure { try await hosts.lease(for: target) } == .signInCancelled)
        #expect(opener.calls == 1)
        _ = try await hosts.lease(for: target, fresh: true, asker: Self.secret())
        #expect(opener.calls == 2)
    }
}
