import Foundation

/// Runs blocking `body` on a thread of its own. On the cooperative pool, blocked calls waiting on
/// each other can take every thread a small machine has, and hang the whole test run.
public func onThread<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { result in Thread.detachNewThread { result.resume(returning: body()) } }
}
