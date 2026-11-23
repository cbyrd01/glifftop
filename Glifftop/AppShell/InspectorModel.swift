import GliffSession

extension SessionModel {
    /// What a new session tells of its frames: the protocol inspector, in Debug builds only.
    var protocolObserver: (any ProtocolObserver)? {
        #if DEBUG
            InspectorModel.Observer(window: windowID)
        #else
            nil
        #endif
    }
}

#if DEBUG
    import Foundation
    import Synchronization

    /// The protocol inspector's numbers (Debug builds): a `ProtocolTally` per window's session,
    /// filled on the sessions' own tasks. Message types, directions, sizes and times only, never
    /// a body or payload.
    nonisolated final class InspectorModel: Sendable {
        static let shared = InspectorModel()

        private let tallies = Mutex<[UUID: ProtocolTally]>([:])

        /// One window's sessions, each reconnect's too.
        nonisolated struct Observer: ProtocolObserver {
            let window: UUID

            func observed(_ event: ProtocolEvent) {
                InspectorModel.shared.tallies.withLock { $0[window, default: ProtocolTally()].add(event) }
            }
        }

        func tally(for model: SessionModel) -> ProtocolTally {
            tallies.withLock { $0[model.windowID] } ?? ProtocolTally()
        }

        /// The window closed.
        func remove(_ model: SessionModel) {
            _ = tallies.withLock { $0.removeValue(forKey: model.windowID) }
        }

        func clear() { tallies.withLock { $0.removeAll() } }
    }
#endif
