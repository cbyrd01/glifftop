import Foundation
import GliffMachines
import Observation

/// The saved machines, kept in `UserDefaults` (key `machines`) as GliffMachines' JSON and
/// written back after each change. Nothing about them is logged.
@Observable final class MachineStore {
    static let key = "machines"
    /// The app's machines, which every window shows and keeps.
    static let shared = MachineStore()

    private(set) var list: MachineList
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        list = MachineList(data: defaults.data(forKey: Self.key))
    }

    /// A session to `destination` streamed with `options`: its machine, added or updated.
    @discardableResult func connected(_ destination: String, options: MachineOptions) -> Machine {
        let machine = list.connected(destination, options: options, at: .now)
        store()
        return machine
    }

    /// The saved machine with `id`, if it's still kept.
    func machine(id: UUID) -> Machine? {
        list.machines.first { $0.id == id }
    }

    func save(_ machine: Machine) {
        list.save(machine)
        store()
    }

    /// The machine sheet saved `machine` (`MachineList.saveEdit`).
    func saveEdit(_ machine: Machine) {
        list.saveEdit(machine)
        store()
    }

    func remove(id: UUID) {
        list.remove(id: id)
        store()
    }

    private func store() {
        defaults.set(list.data(), forKey: Self.key)
    }
}
