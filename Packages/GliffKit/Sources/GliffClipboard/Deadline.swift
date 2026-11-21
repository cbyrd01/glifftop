import Synchronization

/// How a call run against a deadline ended.
enum DeadlineOutcome<Value: Sendable>: Sendable {
    case done(Value)
    case failed
    case timedOut
    case cancelled
}

/// Runs a sink's or source's call off the actor, giving up on it after `limit` or once the
/// caller is cancelled (upstream bounds each such call by its idle timeout), so a paste target
/// or a source that hangs cannot pin a transfer. A call that ignores cancellation is left to end
/// on its own.
@concurrent func withDeadline<Value: Sendable>(
    _ limit: Duration, _ call: @escaping @Sendable () async throws -> Value
) async -> DeadlineOutcome<Value> {
    let first = FirstOutcome<Value>()
    let work = Task {
        do { first.settle(.done(try await call())) } catch { first.settle(.failed) }
    }
    let timer = Task {
        do { try await Task.sleep(for: limit) } catch { return }
        first.settle(.timedOut)
    }
    defer {
        timer.cancel()
        work.cancel()
    }
    return await withTaskCancellationHandler {
        await withCheckedContinuation { first.wait($0) }
    } onCancel: {
        first.settle(.cancelled)
    }
}

/// Keeps the first outcome and hands it to the one waiter, whichever comes first.
private final class FirstOutcome<Value: Sendable>: Sendable {
    private enum State {
        case pending
        case waiting(CheckedContinuation<DeadlineOutcome<Value>, Never>)
        case settled(DeadlineOutcome<Value>)
        case finished
    }

    private let state = Mutex<State>(.pending)

    func wait(_ waiter: CheckedContinuation<DeadlineOutcome<Value>, Never>) {
        let ready: DeadlineOutcome<Value>? = state.withLock { state in
            guard case .settled(let outcome) = state else {
                state = .waiting(waiter)
                return nil
            }
            state = .finished
            return outcome
        }
        if let ready { waiter.resume(returning: ready) }
    }

    func settle(_ outcome: DeadlineOutcome<Value>) {
        let waiter: CheckedContinuation<DeadlineOutcome<Value>, Never>? = state.withLock { state in
            switch state {
            case .pending:
                state = .settled(outcome)
                return nil
            case .waiting(let waiter):
                state = .finished
                return waiter
            case .settled, .finished:
                return nil
            }
        }
        waiter?.resume(returning: outcome)
    }
}
