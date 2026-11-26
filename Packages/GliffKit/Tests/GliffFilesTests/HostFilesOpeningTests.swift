import Foundation
import GliffSFTP
import GliffTestSupport
import GliffTransport
import Synchronization
import Testing

@testable import GliffFiles

/// Records the questions put to it and answers each with Cancel.
final class RecordingAsker: SignInAsker {
    private let asked = Mutex(0)

    var questions: Int { asked.withLock { $0 } }

    func ask(_ question: SignInQuestion) async -> SignInAnswer {
        asked.withLock { $0 += 1 }
        return .cancel
    }
}

/// The channel's opening, shared by the users waiting for it.
@Suite struct HostFilesOpeningTests {
    /// An opening everyone stopped waiting for isn't joined: the next request opens afresh.
    @Test func aRequestAfterAnAbandonedOpeningOpensAgain() async throws {
        let (gate, open) = AsyncStream<Void>.makeStream()
        defer { open.finish() }
        let transport = PeerTransport(numbered: { number async throws(TransportError) in
            // The first connect ignores its cancellation until the gate opens.
            if number == 1 { await Task { for await _ in gate {} }.value }
            return UploadPeer().connection
        })
        let files = HostFiles.testing(files: transport)
        let (first, second) = (await files.join(asker: nil), await files.join(asker: nil))
        let abandoned = Task { try await files.session(for: first) }
        #expect(await eventually { transport.connects == 1 })
        abandoned.cancel()
        await #expect(throws: FilesError.cancelled) { try await abandoned.valueWithin() }

        let session = try await Task { try await files.session(for: second) }.valueWithin()
        #expect(transport.connects == 2)
        open.finish()
        try await Task.sleep(for: .milliseconds(100))
        #expect(try await Task { try await files.session(for: second) }.valueWithin() === session)
        await files.leave(first)
        await files.leave(second)
    }

    /// A sign-in question goes to a user still waiting, not to the one who started the opening
    /// and left.
    @Test func aQuestionGoesToAUserStillThere() async throws {
        let (gate, open) = AsyncStream<Void>.makeStream()
        defer { open.finish() }
        let connects = Mutex(0)
        let channels = FilesChannels(
            files: { asker in
                PeerTransport { () async throws(TransportError) in
                    connects.withLock { $0 += 1 }
                    for await _ in gate {}
                    _ = await asker?.ask(.notice(host: "omarchy", text: "Touch your security key"))
                    return UploadPeer().connection
                }
            },
            command: { _, _ in PeerTransport.folders(home: "/home/person") })
        let files = HostFiles(
            host: "omarchy", channels: channels, ledger: TemporaryLedger(store: MemoryLedgerStore()),
            activity: RecordingActivity())
        let (leaving, staying) = (RecordingAsker(), RecordingAsker())
        let first = await files.join(asker: leaving)
        let second = await files.join(asker: staying)
        let left = Task { try await files.session(for: first) }
        #expect(await eventually { connects.withLock { $0 } == 1 })
        let waiting = Task { try await files.session(for: second) }
        #expect(await eventually { await files.waiters.count == 2 })
        left.cancel()
        await files.leave(first)
        open.finish()

        _ = try await waiting.valueWithin()
        #expect(staying.questions == 1)
        #expect(leaving.questions == 0)
        await files.leave(second)
    }
}
