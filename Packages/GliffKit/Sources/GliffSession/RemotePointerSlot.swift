import Synchronization

/// Where the host's pointer is, from its CursorPos messages: the session writes, the app reads.
public final class RemotePointerSlot: Sendable {
    /// A pointer position in capture-buffer pixels, and whether the host shows a pointer.
    public struct Position: Equatable, Sendable {
        public var x, y: Double
        public var visible: Bool

        public init(x: Double, y: Double, visible: Bool) { (self.x, self.y, self.visible) = (x, y, visible) }
    }

    /// The most recent reports kept for `reports(after:)`: more than arrive between two of the
    /// display's frames.
    public static let recentLimit = 64

    /// The last `recentLimit` reports, a ring indexed by generation; the latest is at
    /// `generation`'s place (none before the first).
    private let state = Mutex<(generation: UInt64, recent: [Position?])>(
        (0, Array(repeating: nil, count: recentLimit)))

    public init() {}

    /// The last CursorPos: nil before one, after a StreamConfig that brings a new picture (a
    /// new size or codec), and once the session has ended.
    public var latest: Position? { read().position }

    /// The last CursorPos and how many have been published: a reader that polls sees a new
    /// report, even one at the same place, by its generation.
    public func read() -> (position: Position?, generation: UInt64) {
        state.withLock { ($0.recent[Self.place($0.generation)], $0.generation) }
    }

    /// The reports published after `generation`, oldest first (at most `recentLimit`), and the
    /// generation now: a reader that polls sees a host move followed at once by another report.
    /// A generation not reached yet (another slot's) gets none.
    public func reports(after generation: UInt64) -> (positions: [Position?], generation: UInt64) {
        state.withLock { state in
            guard generation < state.generation else { return ([], state.generation) }
            let missed = min(state.generation - generation, UInt64(Self.recentLimit))
            let positions = (0..<missed).reversed().map { state.recent[Self.place(state.generation &- $0)] }
            return (positions, state.generation)
        }
    }

    func publish(_ latest: Position?) {
        state.withLock {
            $0.generation &+= 1
            $0.recent[Self.place($0.generation)] = latest
        }
    }

    private static func place(_ generation: UInt64) -> Int { Int(generation % UInt64(recentLimit)) }
}
