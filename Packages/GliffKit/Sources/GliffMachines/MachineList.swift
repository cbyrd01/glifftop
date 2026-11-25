public import Foundation
internal import GliffMacros

/// The saved machines, in the order the list shows them: favourites, then the most recently
/// connected, then by name. Each destination once (trimmed). Stored as JSON by the app; an
/// entry it can't read, or a destination stored twice, is skipped and the rest kept, so the
/// next store drops it for good.
public struct MachineList: Equatable, Sendable {
    public private(set) var machines: [Machine] = []

    /// The list stored as `data`; none if nil or unreadable.
    public init(data: Data?) {
        guard let data, let entries = try? JSONDecoder().decode([Lossy<Machine>].self, from: data) else {
            return
        }
        for case let machine? in entries.map(\.value) where self.machine(for: machine.destination) == nil {
            machines.append(Self.trimming(machine))
        }
        sort()
    }

    /// The list to store.
    public func data() -> Data {
        // Encoding plain values can't fail.
        (try? JSONEncoder().encode(machines)) ?? Data("[]".utf8)
    }

    /// The machine with this destination, ignoring surrounding white space.
    public func machine(for destination: String) -> Machine? {
        let destination = Self.trimmed(destination)
        return machines.first { $0.destination == destination }
    }

    /// A connection to `destination` streamed: its machine, added (named for its destination)
    /// or found, now has these options and this date.
    @discardableResult public mutating func connected(
        _ destination: String, options: MachineOptions, at date: Date
    ) -> Machine {
        let destination = Self.trimmed(destination)
        var machine = machine(for: destination) ?? Machine(name: destination, destination: destination)
        machine.options = options
        machine.lastConnected = date
        save(machine)
        return machine
    }

    /// Adds the machine, or replaces the one with its id; its destination trimmed. Another
    /// machine with that destination is removed, so each destination is kept once, and its
    /// macros follow this machine's (`macrosAfterSave`). The macros kept are the first that
    /// fit, as a read keeps them: the sheet validates `macrosAfterSave` first.
    public mutating func save(_ machine: Machine) {
        var machine = Self.trimming(machine)
        machine.macros = Machine.fitting(macrosAfterSave(machine))
        machines.removeAll { $0.destination == machine.destination && $0.id != machine.id }
        if let index = machines.firstIndex(where: { $0.id == machine.id }) {
            machines[index] = machine
        } else {
            machines.append(machine)
        }
        sort()
    }

    /// The machine sheet saved `machine`, a copy taken when it opened: what the sheet doesn't
    /// show (the favourite, the last connection, the macros' approvals) stays as stored. A
    /// macro keeps its stored approval only while its script (byte for byte) and moment do.
    public mutating func saveEdit(_ machine: Machine) {
        var edited = machine
        let stored = machines.first { $0.id == machine.id }
        if let stored {
            (edited.isFavorite, edited.lastConnected) = (stored.isFavorite, stored.lastConnected)
        }
        for index in edited.macros.indices {
            let macro = edited.macros[index]
            let old = stored?.macros.first { $0.id == macro.id }
            edited.macros[index].approval = old.flatMap {
                $0.moment == macro.moment && $0.hasScript(macro.script) ? $0.approval : nil
            }
        }
        save(edited)
    }

    public mutating func remove(id: UUID) {
        machines.removeAll { $0.id == id }
    }

    private mutating func sort() {
        machines.sort { a, b in
            if a.isFavorite != b.isFavorite { return a.isFavorite }
            if a.lastConnected != b.lastConnected {
                return (a.lastConnected ?? .distantPast) > (b.lastConnected ?? .distantPast)
            }
            let byName = a.name.localizedStandardCompare(b.name)
            if byName != .orderedSame { return byName == .orderedAscending }
            return a.id.uuidString < b.id.uuidString
        }
    }

    private static func trimming(_ machine: Machine) -> Machine {
        var machine = machine
        machine.destination = trimmed(machine.destination)
        return machine
    }

    static func trimmed(_ destination: String) -> String {
        destination.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
