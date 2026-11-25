import Foundation
import Testing

@testable import GliffMacros

/// A stored macro reads back as written, and anything missing or unreadable takes its moment's
/// default, so a store edited by hand or by another version never loses a machine.
@Suite struct MacroDecodingTests {
    private let id = UUID(uuidString: "6F1C0000-0000-4000-8000-000000000001")!

    private func json(_ fields: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: fields)
    }

    private func full(moment: String = "ready") -> [String: Any] {
        [
            "id": id.uuidString, "name": "Layout", "moment": moment, "runs": "firstConnect",
            "script": "echo hi\n", "isEnabled": false, "timeLimit": 7,
            "stopsSessionOnFailure": true, "approval": Data([1, 2, 3]).base64EncodedString(),
        ]
    }

    private func decode(_ fields: [String: Any]) throws -> Macro {
        try JSONDecoder().decode(Macro.self, from: try json(fields))
    }

    @Test func macroRoundTrips() throws {
        let macro = Macro(
            id: id, name: "Layout", moment: .before, runs: .everyConnect, script: "echo hi\n",
            isEnabled: false, timeLimit: 12, stopsSessionOnFailure: true, approval: Data([9]))
        let back = try JSONDecoder().decode(Macro.self, from: JSONEncoder().encode(macro))
        #expect(back == macro)
    }

    enum Field: String, CaseIterable, Sendable {
        case name, runs, isEnabled, timeLimit, stopsSessionOnFailure, approval
    }

    @Test(arguments: Field.allCases, MacroMoment.allCases)
    func eachMissingFieldTakesItsMomentsDefault(field: Field, moment: MacroMoment) throws {
        var fields = full(moment: moment.rawValue)
        fields[field.rawValue] = nil
        let macro = try decode(fields)
        switch field {
        case .name: #expect(macro.name == Macro.defaultName)
        case .runs: #expect(macro.runs == moment.defaultRuns)
        case .isEnabled: #expect(macro.isEnabled)
        case .timeLimit: #expect(macro.timeLimit == moment.defaultLimit)
        case .stopsSessionOnFailure: #expect(!macro.stopsSessionOnFailure)
        case .approval: #expect(macro.approval == nil)
        }
    }

    @Test func aWrongTypeTakesTheDefault() throws {
        var fields = full()
        fields["timeLimit"] = "soon"
        fields["isEnabled"] = "yes"
        fields["runs"] = "sometimes"
        let macro = try decode(fields)
        #expect(macro.timeLimit == MacroMoment.ready.defaultLimit)
        #expect(macro.isEnabled)
        #expect(macro.runs == .everyConnect)
    }

    @Test func timeLimitIsClamped() throws {
        var fields = full(moment: "before")
        fields["timeLimit"] = 600
        #expect(try decode(fields).timeLimit == 60)
        fields["timeLimit"] = 0
        #expect(try decode(fields).timeLimit == 1)
        var ready = full(moment: "ready")
        ready["timeLimit"] = 1000
        #expect(try decode(ready).timeLimit == 300)
        var disconnect = full(moment: "disconnect")
        disconnect["timeLimit"] = 60
        #expect(try decode(disconnect).timeLimit == 5)
    }

    @Test func stopsSessionOnlyForBefore() throws {
        #expect(try decode(full(moment: "before")).stopsSessionOnFailure)
        for moment in ["ready", "manual", "disconnect"] {
            #expect(try !decode(full(moment: moment)).stopsSessionOnFailure)
        }
        let made = Macro(name: "x", moment: .ready, script: "true", stopsSessionOnFailure: true)
        #expect(!made.stopsSessionOnFailure)
    }

    @Test func malformedApprovalIsNil() throws {
        var fields = full()
        fields["approval"] = "not base64 !!"
        #expect(try decode(fields).approval == nil)
        fields["approval"] = 42
        #expect(try decode(fields).approval == nil)
    }

    @Test func nameIsCleanedAndCut() throws {
        var fields = full()
        fields["name"] = "La\u{1B}[31myout\u{202E}"
        #expect(try decode(fields).name == "La[31myout")
        fields["name"] = String(repeating: "n", count: 150)
        #expect(try decode(fields).name.count == 100)
        let made = Macro(name: "A\u{202E}B", moment: .ready, script: "true")
        #expect(made.name == "AB")
    }

    @Test(arguments: ["", "\u{202E}\u{1B}", "   "])
    func anEmptyNameTakesTheDefault(_ name: String) throws {
        var fields = full()
        fields["name"] = name
        #expect(try decode(fields).name == Macro.defaultName)
        #expect(Macro(name: name, moment: .ready, script: "true").name == Macro.defaultName)
    }

    @Test func lineBreaksAndTabsInANameBecomeSpaces() {
        #expect(
            Macro(name: "Open\tthe\nLayout\u{2028}now", moment: .ready, script: "true").name
                == "Open the Layout now")
    }

    @Test func changingTheMomentKeepsTheRules() {
        var macro = Macro(name: "x", moment: .ready, script: "true", timeLimit: 300)
        macro.moment = .before
        #expect(macro.timeLimit == 60)
        macro.stopsSessionOnFailure = true
        #expect(macro.stopsSessionOnFailure)
        macro.moment = .manual
        #expect(!macro.stopsSessionOnFailure)
        macro.stopsSessionOnFailure = true
        #expect(!macro.stopsSessionOnFailure)
        macro.moment = .disconnect
        #expect(macro.timeLimit == 5)
    }

    @Test func settingTheLimitClampsIt() {
        var macro = Macro(name: "x", moment: .before, script: "true")
        macro.timeLimit = 0
        #expect(macro.timeLimit == 1)
        macro.timeLimit = 61
        #expect(macro.timeLimit == 60)
    }

    @Test func settingANameCleansIt() {
        var macro = Macro(name: "x", moment: .before, script: "true")
        macro.name = "A\u{202E}B"
        #expect(macro.name == "AB")
        macro.name = String(repeating: "n", count: 150)
        #expect(macro.name.count == 100)
    }

    @Test func aMacroMadeWithARefusedScriptIsDisabled() {
        #expect(!Macro(name: "x", moment: .ready, script: "a\u{202E}").isEnabled)
    }

    @Test func unknownMomentThrows() {
        var fields = full()
        fields["moment"] = "sometime"
        #expect(throws: (any Error).self) { try decode(fields) }
    }

    @Test(arguments: ["id", "script", "moment"])
    func aMissingRequiredFieldThrows(field: String) {
        var fields = full()
        fields[field] = nil
        #expect(throws: (any Error).self) { try decode(fields) }
    }

    @Test func aRefusedScriptIsKeptDisabled() throws {
        var fields = full()
        fields["isEnabled"] = true
        fields["script"] = "echo \u{202E}hi\n"
        let macro = try decode(fields)
        #expect(macro.script == "echo \u{202E}hi\n")
        #expect(!macro.isEnabled)
        #expect(!macro.canRun)
    }

    @Test func anOversizedScriptIsKeptDisabled() throws {
        var fields = full()
        fields["isEnabled"] = true
        fields["script"] = String(repeating: "#", count: MacroLimits.scriptBytes + 1)
        let macro = try decode(fields)
        #expect(!macro.isEnabled)
        #expect(!macro.canRun)
    }
}
