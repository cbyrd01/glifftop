import Synchronization

/// How far a batch has come, counted as it runs and read (polled) by whoever shows it.
public final class TransferProgress: Sendable {
    public struct Counts: Equatable, Sendable {
        public var itemsDone = 0
        public var itemsTotal: Int
        public var bytesDone: UInt64 = 0
        public var bytesTotal: UInt64
        /// Top-level items finished, in the plan's order: a later try starts after them.
        public var topLevelDone = 0
        /// Files that were no longer regular files when they were opened.
        public var specialsSkipped = 0
        /// Items given " 2" inside a batch's folder, as this Mac takes their names as one.
        public var renamed = 0
    }

    private let state: Mutex<Counts>

    public init<Source, Destination>(_ plan: TransferPlan<Source, Destination>) {
        state = Mutex(Counts(itemsTotal: plan.items.count, bytesTotal: plan.totalBytes))
    }

    public var counts: Counts { state.withLock { $0 } }

    func add(bytes: UInt64) {
        state.withLock { counts in
            // A file that grew while it copied never takes the count past the plan's.
            let (sum, overflow) = counts.bytesDone.addingReportingOverflow(bytes)
            counts.bytesDone = overflow ? counts.bytesTotal : min(sum, counts.bytesTotal)
        }
    }

    func finishItem() { state.withLock { $0.itemsDone += 1 } }

    func finishTopLevel() { state.withLock { $0.topLevelDone += 1 } }

    func skipSpecial() { state.withLock { $0.specialsSkipped += 1 } }

    func rename() { state.withLock { $0.renamed += 1 } }
}
