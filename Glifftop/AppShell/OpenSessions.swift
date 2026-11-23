import Foundation
import GliffInput
import Observation

/// The open windows' models, in opening order, held weakly: what a new tab, a machine's host
/// lock, tab titles and quitting look across.
@Observable final class OpenSessions {
    static let shared = OpenSessions()

    private struct Entry {
        weak var model: SessionModel?
    }

    private var entries: [Entry] = []
    /// Closed windows' sessions still saying Bye, which quitting waits for.
    @ObservationIgnored private var ending: [UUID: Task<Void, Never>] = [:]

    /// The models still open.
    var models: [SessionModel] { entries.compactMap(\.model) }

    /// A window opened with `model`; again is harmless.
    func add(_ model: SessionModel) {
        guard !models.contains(where: { $0 === model }) else { return }
        entries = entries.filter { $0.model != nil } + [Entry(model: model)]
    }

    /// `model`'s window closed: its session ends as Disconnect does, and quitting meanwhile
    /// still waits for its Bye.
    func close(_ model: SessionModel) {
        entries.removeAll { $0.model == nil || $0.model === model }
        let id = UUID()
        ending[id] = Task {
            await model.shutdown()
            #if DEBUG
                // After shutdown: its Bye and the replies are counted too.
                InspectorModel.shared.remove(model)
            #endif
            ending[id] = nil
        }
    }

    /// ⌘⇧[ or ⌘⇧] from window `window` (a window number): its previous or next tab, else the
    /// previous or next session window in opening order.
    func selectTab(_ chord: TabChord, from window: Int?) {
        TabSwitcher.select(chord, from: window, order: models.compactMap { $0.tabGroup?.window })
    }

    /// Whether a session to `host` (as typed: compared trimmed, as machines are) is shown in a
    /// window other than `model`'s.
    func isOpen(_ host: String, besides model: SessionModel) -> Bool {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        return models.contains { $0 !== model && $0.isActive && $0.host == host }
    }

    /// Ends every window's session and waits for each to end, closed windows' too, for quitting.
    func shutdownAll() async {
        let closing = Array(ending.values)
        await withTaskGroup { group in
            for model in models { group.addTask { await model.shutdown() } }
            for task in closing { group.addTask { await task.value } }
        }
    }
}
