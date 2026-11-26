import Synchronization

/// The first failure among requests running at once; later ones are dropped.
final class FirstFailure: Sendable {
    private let failure = Mutex<FilesError?>(nil)

    /// Whether nothing has failed yet, so new requests may go.
    var isClear: Bool { failure.withLock { $0 == nil } }

    func record(_ error: FilesError) { failure.withLock { $0 = $0 ?? error } }

    /// Throws the first failure, if any.
    func check() throws(FilesError) {
        if let error = failure.withLock({ $0 }) { throw error }
    }
}
