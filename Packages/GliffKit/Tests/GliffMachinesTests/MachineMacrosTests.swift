import Foundation
import GliffMacros
import GliffSession
import GliffTransport
import Testing

@testable import GliffMachines

/// A machine keeps its macros; a store with no macros, or with a macro another version wrote,
/// still reads every machine.
@Suite struct MachineMacrosTests {
    private let day = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// A stored list with no `macros` keys.
    private static let storeWithoutMacros = #"""
        [{"id":"0E1F0000-0000-4000-8000-000000000001","name":"Desk","destination":"omarchy",
          "options":{"screen":{"virtual":{}},"textSize":0.75,"resolution":"automatic",
                     "scaleToFit":false,"reconnects":true},
          "isFavorite":true,"lastConnected":800000000},
         {"id":"0E1F0000-0000-4000-8000-000000000002","name":"Lab","destination":"person@192.0.2.10",
          "options":{"screen":{"focused":{}}},"isFavorite":false}]
        """#

    private func machineJSON(macros: Any?) throws -> Data {
        var machine: [String: Any] = [
            "id": UUID().uuidString, "name": "Desk", "destination": "omarchy",
            "options": ["screen": ["virtual": [:]]], "isFavorite": false,
        ]
        if let macros { machine["macros"] = macros }
        return try JSONSerialization.data(withJSONObject: [machine])
    }

    private func macro(_ name: String, moment: String = "ready", script: String = "true\n") -> [String: Any] {
        ["id": UUID().uuidString, "name": name, "moment": moment, "script": script]
    }

    @Test func aStoreWithoutMacrosDecodesEveryMachine() {
        let list = MachineList(data: Data(Self.storeWithoutMacros.utf8))
        #expect(list.machines.map(\.name) == ["Desk", "Lab"])
        #expect(list.machines.allSatisfy { $0.macros.isEmpty })
        #expect(list.machines.first?.options.screen == .virtual)
        #expect(list.machines.first?.isFavorite == true)
        #expect(list.machines.first?.options.textSize == .f75)
    }

    @Test func macrosNotAnArrayDecodesEmpty() throws {
        let list = MachineList(data: try machineJSON(macros: ["not": "a list"]))
        #expect(list.machines.count == 1)
        #expect(list.machines.first?.macros == [])
    }

    @Test func anUnknownMomentDropsOnlyThatMacro() throws {
        let data = try machineJSON(macros: [macro("A"), macro("B", moment: "someday"), macro("C")])
        #expect(MachineList(data: data).machines.first?.macros.map(\.name) == ["A", "C"])
    }

    @Test func aBrokenEntryKeepsTheOthers() throws {
        var noScript = macro("B")
        noScript["script"] = nil
        let data = try machineJSON(macros: [macro("A"), noScript, 42, macro("C")])
        #expect(MachineList(data: data).machines.first?.macros.map(\.name) == ["A", "C"])
    }

    @Test func aRepeatedMacroIDKeepsTheFirst() throws {
        var first = macro("A")
        var again = macro("B")
        again["id"] = first["id"]
        first["approval"] = Data([1]).base64EncodedString()
        let data = try machineJSON(macros: [first, again, macro("C")])
        #expect(MachineList(data: data).machines.first?.macros.map(\.name) == ["A", "C"])
    }

    @Test func limitsKeepTheFirstThatFit() throws {
        let many = (0..<25).map { macro("m\($0)") }
        let counted = MachineList(data: try machineJSON(macros: many)).machines.first?.macros
        #expect(counted?.count == MacroLimits.macrosPerMachine)
        #expect(counted?.first?.name == "m0")

        let big = String(repeating: "#", count: 60 * 1024)
        let sized = (0..<6).map { macro("s\($0)", script: big) }
        let kept = MachineList(data: try machineJSON(macros: sized)).machines.first?.macros
        #expect(kept?.map(\.name) == ["s0", "s1", "s2", "s3"])
    }

    @Test func saveEditKeepsStoredApprovals() {
        var list = MachineList(data: nil)
        var machine = list.connected("omarchy", options: MachineOptions(), at: day)
        let kept = Macro(name: "Layout", moment: .ready, script: "true\n", approval: Data([1]))
        machine.macros = [kept]
        list.save(machine)

        var sheet = machine
        sheet.macros[0].approval = Data([9])
        sheet.macros[0].name = "Renamed"
        sheet.macros.append(Macro(name: "New", moment: .manual, script: "true\n", approval: Data([7])))
        list.saveEdit(sheet)

        let saved = list.machines.first?.macros
        #expect(saved?.map(\.name) == ["Renamed", "New"])
        #expect(saved?.first?.approval == Data([1]))
        #expect(saved?.last?.approval == nil)
    }

    @Test func approvingStoresOneMacrosApproval() {
        var list = MachineList(data: nil)
        var machine = list.connected("omarchy", options: MachineOptions(), at: day)
        let macro = Macro(name: "Layout", moment: .ready, script: "true\n")
        machine.macros = [macro]
        list.save(machine)
        list.approve(macroID: macro.id, script: "true\n", of: machine.id, approval: Data([5]))
        #expect(list.machines.first?.macros.first?.approval == Data([5]))
        // The text changed since the question: the answer isn't stored.
        list.approve(macroID: macro.id, script: "false\n", of: machine.id, approval: Data([6]))
        #expect(list.machines.first?.macros.first?.approval == Data([5]))
    }

    /// Saving a machine onto another's destination replaces that machine but keeps its scripts,
    /// unapproved (an approval names its machine).
    @Test func replacingAMachineKeepsItsMacros() {
        var list = MachineList(data: nil)
        var old = list.connected("omarchy", options: MachineOptions(), at: day)
        old.macros = [Macro(name: "Old", moment: .ready, script: "true\n", approval: Data([1]))]
        list.save(old)
        var new = Machine(name: "New", destination: "omarchy")
        new.macros = [Macro(name: "Mine", moment: .manual, script: "true\n")]
        list.saveEdit(new)
        #expect(list.machines.map(\.name) == ["New"])
        #expect(list.machines.first?.macros.map(\.name) == ["Mine", "Old"])
        #expect(list.machines.first?.macros.allSatisfy { $0.approval == nil } == true)
    }

    @Test func anEditedScriptOrMomentLosesItsApproval() {
        var list = MachineList(data: nil)
        var machine = list.connected("omarchy", options: MachineOptions(), at: day)
        let kept = Macro(name: "Kept", moment: .ready, script: "true\n", approval: Data([1]))
        let edited = Macro(name: "Script", moment: .ready, script: "true\n", approval: Data([2]))
        let moved = Macro(name: "Moment", moment: .ready, script: "true\n", approval: Data([3]))
        machine.macros = [kept, edited, moved]
        list.save(machine)
        var sheet = machine
        sheet.macros[0].name = "Renamed"
        sheet.macros[1].script = "false\n"
        sheet.macros[2].moment = .manual
        list.saveEdit(sheet)
        #expect(list.machines.first?.macros.map(\.approval) == [Data([1]), nil, nil])
    }

    /// An approval names its host: pointing the machine elsewhere asks again.
    @Test func anEditedDestinationLosesTheApprovals() {
        var list = MachineList(data: nil)
        var machine = list.connected("omarchy", options: MachineOptions(), at: day)
        machine.macros = [Macro(name: "A", moment: .ready, script: "true\n", approval: Data([1]))]
        list.save(machine)
        var sheet = machine
        sheet.destination = " omarchy "
        list.saveEdit(sheet)
        #expect(list.machines.first?.macros.first?.approval == Data([1]))
        sheet.destination = "other"
        list.saveEdit(sheet)
        #expect(list.machines.first?.macros.first?.approval == nil)
    }

    @Test func anySaveToANewDestinationDropsTheApprovals() {
        var list = MachineList(data: nil)
        var machine = list.connected("omarchy", options: MachineOptions(), at: day)
        machine.macros = [Macro(name: "A", moment: .ready, script: "true\n", approval: Data([1]))]
        list.save(machine)
        machine.destination = "other"
        #expect(list.macrosAfterSave(machine).first?.approval == nil)
        list.save(machine)
        #expect(list.machines.first?.macros.first?.approval == nil)
    }

    @Test func anIDDroppedForSizeIsNotTakenAgain() throws {
        let big = String(repeating: "#", count: 60 * 1024)
        var first = macro("Big", script: big)
        var second = macro("Small")
        second["id"] = first["id"]
        first["script"] = big + big + big + big + big
        let data = try machineJSON(macros: [first, second])
        #expect(MachineList(data: data).machines.first?.macros.isEmpty == true)
    }

    /// The sheet checks the list a save would keep, the replaced machine's macros included.
    @Test func theSheetSeesTheMergedMacros() {
        var list = MachineList(data: nil)
        var old = list.connected("omarchy", options: MachineOptions(), at: day)
        old.macros = (0..<10).map { Macro(name: "o\($0)", moment: .manual, script: "true\n") }
        list.save(old)
        var new = Machine(name: "New", destination: " omarchy")
        new.macros = (0..<15).map { Macro(name: "n\($0)", moment: .manual, script: "true\n") }
        let merged = list.macrosAfterSave(new)
        #expect(merged.count == 25)
        #expect(MachineList.validate(macros: merged) == .tooMany)
        #expect(list.macrosAfterSave(old).count == 10)
    }

    /// A replaced machine's macro with an id the saved one has is not counted twice.
    @Test func theMergedMacrosHoldEachIDOnce() {
        var list = MachineList(data: nil)
        var old = list.connected("omarchy", options: MachineOptions(), at: day)
        old.macros = (0..<12).map { Macro(name: "o\($0)", moment: .manual, script: "true\n") }
        list.save(old)
        var new = Machine(name: "New", destination: "omarchy")
        new.macros =
            Array(old.macros.prefix(4))
            + (0..<8).map { Macro(name: "n\($0)", moment: .manual, script: "true\n") }
        let merged = list.macrosAfterSave(new)
        #expect(merged.count == 20)
        #expect(Set(merged.map(\.id)).count == 20)
        #expect(MachineList.validate(macros: merged) == nil)
    }

    /// What is saved reads back the same: the limits and one of each id apply on save too.
    @Test func savingKeepsTheFirstThatFit() {
        var list = MachineList(data: nil)
        var machine = list.connected("omarchy", options: MachineOptions(), at: day)
        let first = Macro(name: "A", moment: .ready, script: "true\n")
        var again = Macro(name: "B", moment: .ready, script: "true\n")
        again.id = first.id
        machine.macros =
            [first, again] + (0..<25).map { Macro(name: "m\($0)", moment: .manual, script: "true\n") }
        list.save(machine)
        let saved = list.machines.first?.macros
        #expect(saved?.count == MacroLimits.macrosPerMachine)
        #expect(saved?.prefix(2).map(\.name) == ["A", "m0"])
        #expect(MachineList(data: list.data()) == list)
    }

    @Test func aScriptThatCantRunIsNeverApproved() {
        var list = MachineList(data: nil)
        var machine = list.connected("omarchy", options: MachineOptions(), at: day)
        let macro = Macro(name: "Layout", moment: .ready, script: "echo \u{202E}hi\n")
        machine.macros = [macro]
        list.save(machine)
        list.approve(macroID: macro.id, script: macro.script, of: machine.id, approval: Data([5]))
        #expect(list.machines.first?.macros.first?.approval == nil)
    }

    @Test func machineRoundTripsWithMacros() {
        var list = MachineList(data: nil)
        var machine = list.connected("omarchy", options: MachineOptions(), at: day)
        machine.macros = [
            Macro(name: "Wake", moment: .before, script: "true\n", stopsSessionOnFailure: true),
            Macro(
                name: "Layout", moment: .ready, runs: .firstConnect, script: "echo é\n", approval: Data([3])),
        ]
        list.save(machine)
        #expect(MachineList(data: list.data()) == list)
    }

    @Test func optionsRecordingLeavesMacros() {
        var list = MachineList(data: nil)
        var machine = list.connected("omarchy", options: MachineOptions(), at: day)
        machine.macros = [Macro(name: "Layout", moment: .ready, script: "true\n")]
        list.save(machine)
        list.connected("omarchy", options: MachineOptions(screen: .virtual), at: day.addingTimeInterval(5))
        #expect(list.machines.first?.macros == machine.macros)
    }

    @Test func validateRefusesTooManyOrTooLarge() {
        let one = Macro(name: "a", moment: .ready, script: "true\n")
        #expect(MachineList.validate(macros: [one]) == nil)
        let many = (0..<21).map { _ in one }
        #expect(MachineList.validate(macros: many) == .tooMany)
        let big = Macro(name: "b", moment: .ready, script: String(repeating: "#", count: 60 * 1024))
        #expect(MachineList.validate(macros: Array(repeating: big, count: 5)) == .tooLarge)
        let huge = Macro(name: "c", moment: .ready, script: String(repeating: "#", count: 65 * 1024))
        #expect(MachineList.validate(macros: [huge]) == .scriptTooLarge(huge.id))
    }
}
