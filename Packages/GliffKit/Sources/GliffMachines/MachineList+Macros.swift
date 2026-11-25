public import Foundation
public import GliffMacros

/// Why the machine sheet can't save a machine's macros.
public enum MacroListProblem: Equatable, Sendable {
    /// More than `MacroLimits.macrosPerMachine`.
    case tooMany
    /// The scripts together pass `MacroLimits.machineScriptBytes`.
    case tooLarge
    /// This macro's script passes `MacroLimits.scriptBytes`.
    case scriptTooLarge(UUID)
}

extension MachineList {
    /// Whether `macros` fit a machine's limits: nil when they do.
    public static func validate(macros: [Macro]) -> MacroListProblem? {
        if macros.count > MacroLimits.macrosPerMachine { return .tooMany }
        if let big = macros.first(where: { $0.script.utf8.count > MacroLimits.scriptBytes }) {
            return .scriptTooLarge(big.id)
        }
        let bytes = macros.reduce(0) { $0 + $1.script.utf8.count }
        return bytes > MacroLimits.machineScriptBytes ? .tooLarge : nil
    }

    /// `machine`'s macros as saving it would keep them, before the limits: its own, then those
    /// of the machine its destination would replace, unapproved (an approval names its
    /// machine).
    public func macrosAfterSave(_ machine: Machine) -> [Macro] {
        let destination = Self.trimmed(machine.destination)
        var macros = machine.macros
        for other in machines where other.destination == destination && other.id != machine.id {
            macros += other.macros.map { macro in
                var macro = macro
                macro.approval = nil
                return macro
            }
        }
        return macros
    }

    /// Always Run: stores `approval` on machine `machineID`'s macro `macroID`, if its script is
    /// still `script` byte for byte (else it changed since the question, and nothing is kept)
    /// and can run.
    public mutating func approve(macroID: UUID, script: String, of machineID: UUID, approval: Data) {
        guard var machine = machines.first(where: { $0.id == machineID }),
            let index = machine.macros.firstIndex(where: { $0.id == macroID }),
            machine.macros[index].hasScript(script), machine.macros[index].canRun
        else { return }
        machine.macros[index].approval = approval
        save(machine)
    }
}
