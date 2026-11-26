import Synchronization

/// Where a batch stands.
public enum TransferState: Equatable, Sendable {
    case queued
    case running
    case finished
    case failed(FilesError)
    case cancelled
}

/// How far a batch has come, counted as it runs and read (polled) by whoever shows it. Each try
/// starts its counts afresh from what it has left to do.
public final class TransferProgress: Sendable {
    public struct Counts: Equatable, Sendable {
        public var state = TransferState.queued
        public var itemsDone = 0
        public var itemsTotal = 0
        public var bytesDone: UInt64 = 0
        public var bytesTotal: UInt64 = 0
        /// Top-level items finished, in the plan's order: a later try starts after them.
        public var topLevelDone = 0
        /// Files that were no longer regular files when they were opened.
        public var specialsSkipped = 0
        /// Items given " 2" inside a batch's folder, as this Mac takes their names as one.
        public var renamed = 0
        /// When this try began running.
        public var started: ContinuousClock.Instant?
    }

    private let state: Mutex<Counts>

    /// A batch not yet planned.
    public init() { state = Mutex(Counts()) }

    public var counts: Counts { state.withLock { $0 } }

    /// Bytes a second since this try began; 0 before it has.
    public func rate(at now: ContinuousClock.Instant = .now) -> Double {
        let (bytes, started) = state.withLock { ($0.bytesDone, $0.started) }
        guard let started else { return 0 }
        let seconds = (now - started) / .seconds(1)
        return seconds > 0 ? Double(bytes) / seconds : 0
    }

    /// A try starts: nothing done yet, its plan not yet known.
    func restart() { state.withLock { $0 = Counts(state: .running) } }

    /// A try begins on `plan`: the counts start again from it.
    func begin<Source, Destination>(_ plan: TransferPlan<Source, Destination>) {
        state.withLock { counts in
            counts = Counts(
                state: .running, itemsTotal: plan.items.count, bytesTotal: plan.totalBytes, started: .now)
        }
    }

    func set(_ state: TransferState) { self.state.withLock { $0.state = state } }

    func add(bytes: UInt64) {
        state.withLock { counts in
            // A file that grew while it copied never takes the count past the plan's.
            counts.bytesDone = min(counts.bytesDone.saturatingAdding(bytes), counts.bytesTotal)
        }
    }

    func finishItem() { state.withLock { $0.itemsDone += 1 } }

    func finishTopLevel() { state.withLock { $0.topLevelDone += 1 } }

    func skipSpecial() { state.withLock { $0.specialsSkipped += 1 } }

    func rename() { state.withLock { $0.renamed += 1 } }
}
