import Synchronization

/// Runs work one piece at a time, in the order it was asked for. A caller's cancel doesn't cut
/// its piece short: a control request ended midway could leave a listener nobody knows of.
final class MasterRequests: Sendable {
    private let tail = Mutex<Task<Void, Never>?>(nil)

    func run<T: Sendable>(_ work: @escaping @Sendable () async -> T) async -> T {
        let task = tail.withLock { tail in
            let previous = tail
            let task = Task<T, Never> {
                await previous?.value
                return await work()
            }
            tail = Task { _ = await task.value }
            return task
        }
        return await task.value
    }
}
