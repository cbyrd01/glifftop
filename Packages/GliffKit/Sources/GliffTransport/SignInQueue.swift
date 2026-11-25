/// A window's sign-in questions, shown one at a time: the oldest is `current`, the rest wait
/// their turn. An ask whose task is cancelled (its connection stopped waiting, or the window
/// closed) is answered `.cancel` and taken away, shown or not.
@MainActor public final class SignInQueue: SignInAsker {
    /// A question being asked, with an id of its own: the same question asked again is a new
    /// one.
    public struct Pending: Identifiable, Equatable, Sendable {
        public let id: Int
        public let question: SignInQuestion
    }

    /// The question to show, nil when none is asked.
    public private(set) var current: Pending? {
        didSet { if current != oldValue { changed?() } }
    }
    /// Called each time `current` changes.
    public var changed: (@MainActor () -> Void)?

    private struct Waiting {
        let pending: Pending
        let slot: AnswerSlot
        let continuation: CheckedContinuation<Void, Never>
    }
    private var waiting: [Waiting] = []
    private var nextID = 0

    public init() {}

    public nonisolated func ask(_ question: SignInQuestion) async -> SignInAnswer {
        await asked(question)
    }

    private func asked(_ question: SignInQuestion) async -> SignInAnswer {
        let pending = Pending(id: nextID, question: question)
        nextID += 1
        let slot = AnswerSlot()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                MainActor.assumeIsolated {
                    guard !Task.isCancelled else { return continuation.resume() }
                    waiting.append(Waiting(pending: pending, slot: slot, continuation: continuation))
                    current = waiting.first?.pending
                }
            }
        } onCancel: {
            Task { @MainActor in self.finish(pending.id) }
        }
        return slot.take() ?? .cancel
    }

    /// Answers the question `id` (`Pending.id`) if it is still the one shown; else the
    /// answer is dropped, so one meant for a question gone never answers the next.
    public func answer(_ answer: consuming SignInAnswer, for id: Int) {
        guard let shown = waiting.first, shown.pending.id == id else { return }
        shown.slot.put(answer)
        finish(shown.pending.id)
    }

    private func finish(_ id: Int) {
        guard let index = waiting.firstIndex(where: { $0.pending.id == id }) else { return }
        waiting.remove(at: index).continuation.resume()
        current = waiting.first?.pending
    }
}
