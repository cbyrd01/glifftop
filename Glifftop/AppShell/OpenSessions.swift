import Foundation
import GliffInput
import GliffMachines
import GliffTransport
import Observation

/// The open windows' models, in opening order, held weakly: what a new tab, a machine's host
/// lock, tab titles, a host reached again and quitting look across.
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

    /// `model`'s session to `destination` streams: the other windows to it whose reconnect
    /// gave up are revived, on the connection now up (an approval that came too late for their
    /// tries, say).
    func reached(_ destination: SSHTarget, by model: SessionModel) {
        for other in models where other !== model && other.destination == destination { other.revive() }
    }

    /// The monitors the windows to `destination` show (`MonitorPlanning`): a live session's
    /// monitor, an ended named mirror's, and whether a live Focused Monitor mirror's output is
    /// still unnamed.
    func shown(for destination: SSHTarget) -> ShownMonitors {
        var shown = ShownMonitors()
        for model in models where model.destination == destination {
            if model.canDisconnect {
                if let monitor = model.mirroredMonitor {
                    shown.live.insert(monitor)
                } else if model.screenChoice == .focused, model.outputName == nil {
                    shown.unnamedFocused = true
                }
            } else if model.canTryAgain, case .named(let name) = model.screenChoice {
                shown.ended.insert(name)
            }
        }
        return shown
    }

    /// The ended window to `destination` of the named monitor `name`, to start again in place.
    func ended(_ name: String, on destination: SSHTarget) -> SessionModel? {
        models.first {
            $0.destination == destination && !$0.canDisconnect && $0.canTryAgain
                && $0.screenChoice == .named(name)
        }
    }

    /// The machine sheet saved `saved`: every window showing it takes its options, so none
    /// records its older ones back over them.
    func machineSaved(_ saved: Machine) {
        for model in models { model.machineSaved(saved) }
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
