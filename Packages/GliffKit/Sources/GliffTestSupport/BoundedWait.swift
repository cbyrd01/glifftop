import Synchronization

/// A test's wait that reached its bound.
public struct TimedOut: Error, Equatable {
    public init() {}
}

extension Task {
    /// The task's outcome, waited for at most `limit` of real time (10 s, as `eventually`):
    /// past it the task is cancelled and left, and this throws `TimedOut`, so a broken test
    /// fails instead of hanging its run. Swift Testing's `.timeLimit` can't: it still waits for
    /// a body that ignores cancellation, such as one awaiting a task's `value`.
    public func resultWithin(_ limit: Duration = .seconds(10)) async throws(TimedOut) -> Result<
        Success, Failure
    > {
        let waiter = OnceWaiter<Result<Success, Failure>>()
        let outcome = await withCheckedContinuation { continuation in
            waiter.start(continuation)
            let timer = Task<Void, Never> {
                try? await Task<Never, Never>.sleep(for: limit)
                waiter.resume(with: nil)
            }
            Task<Void, Never> {
                let result = await self.result
                timer.cancel()
                waiter.resume(with: result)
            }
        }
        guard let outcome else {
            cancel()
            throw TimedOut()
        }
        return outcome
    }

    /// The task's value, waited for at most `limit` (`resultWithin`).
    public func valueWithin(_ limit: Duration = .seconds(10)) async throws -> Success {
        try await resultWithin(limit).get()
    }
}

/// A continuation resumed once, by whichever answer comes first.
private final class OnceWaiter<Value: Sendable>: Sendable {
    private let continuation = Mutex<CheckedContinuation<Value?, Never>?>(nil)

    func start(_ continuation: CheckedContinuation<Value?, Never>) {
        self.continuation.withLock { $0 = continuation }
    }

    func resume(with value: Value?) {
        continuation.withLock { $0.take() }?.resume(returning: value)
    }
}
