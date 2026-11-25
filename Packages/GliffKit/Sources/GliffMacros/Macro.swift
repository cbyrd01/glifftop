public import Foundation
internal import GliffTransport

/// When a macro runs. The raw values are the stored JSON and `GLIFF_MOMENT`'s values.
public enum MacroMoment: String, Codable, Sendable, CaseIterable {
    /// Before the session: blocks the start of gliff-server, up to its limit.
    case before
    /// Once the screen exists, with `GLIFF_OUTPUT`.
    case ready
    /// Only from Connection ▸ Run Macro.
    case manual
    /// When the person disconnects, within `MacroLimits.disconnectBudget` for all of them.
    case disconnect

    /// The time limit a new macro of this moment gets, in seconds.
    public var defaultLimit: Int {
        switch self {
        case .before: 10
        case .ready, .manual: 30
        case .disconnect: 5
        }
    }

    /// The time limits a macro of this moment may have, in seconds.
    public var limitRange: ClosedRange<Int> {
        switch self {
        case .before: 1...60
        case .ready, .manual: 1...300
        case .disconnect: 5...5
        }
    }

    /// How often a new macro of this moment runs; only `before` and `ready` macros read it.
    public var defaultRuns: MacroRuns {
        self == .before ? .firstConnect : .everyConnect
    }
}

/// How often a `before` or `ready` macro runs in one connection.
public enum MacroRuns: String, Codable, Sendable {
    /// At each try and each Screen switch.
    case everyConnect
    /// Once per connection.
    case firstConnect
}

/// The bounds on a machine's macros.
public enum MacroLimits {
    public static let macrosPerMachine = 20
    /// One script's UTF-8 bytes.
    public static let scriptBytes = 64 * 1024
    /// A machine's scripts together, in UTF-8 bytes.
    public static let machineScriptBytes = 256 * 1024
    /// A name's characters.
    public static let nameLength = 100
    /// The time every `disconnect` macro of one Disconnect shares.
    public static let disconnectBudget: Duration = .seconds(5)
}

/// A shell script a saved machine runs on its host at one moment.
public struct Macro: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    /// The person's label: displayable, at most `MacroLimits.nameLength` characters, kept so
    /// by each change. Made or read empty, it is `defaultName`.
    public var name: String {
        didSet { name = Self.cleanName(name) }
    }
    /// A change keeps the limit in the new moment's range, and "Stop the session" for
    /// `before` only.
    public var moment: MacroMoment {
        didSet {
            timeLimit = Self.clamp(timeLimit, to: moment)
            if moment != .before { stopsSessionOnFailure = false }
        }
    }
    public var runs: MacroRuns
    public var script: String
    public var isEnabled: Bool
    /// Seconds, within the moment's `limitRange`.
    public var timeLimit: Int {
        didSet { timeLimit = Self.clamp(timeLimit, to: moment) }
    }
    /// `before` only: a failure at a person's connect ends the session.
    public var stopsSessionOnFailure: Bool {
        didSet { if moment != .before { stopsSessionOnFailure = false } }
    }
    /// The approval's MAC, nil until Always Run.
    public var approval: Data?

    /// The name a macro made or stored without one gets.
    static let defaultName = "Macro"

    /// A script that can't run (`canRun`) is made disabled.
    public init(
        id: UUID = UUID(), name: String, moment: MacroMoment, runs: MacroRuns? = nil, script: String,
        isEnabled: Bool = true, timeLimit: Int? = nil, stopsSessionOnFailure: Bool = false,
        approval: Data? = nil
    ) {
        self.id = id
        let name = Self.cleanName(name)
        self.name = name.allSatisfy(\.isWhitespace) ? Self.defaultName : name
        self.moment = moment
        self.runs = runs ?? moment.defaultRuns
        self.script = script
        self.isEnabled = isEnabled
        self.timeLimit = Self.clamp(timeLimit ?? moment.defaultLimit, to: moment)
        self.stopsSessionOnFailure = moment == .before && stopsSessionOnFailure
        self.approval = approval
        if !canRun { self.isEnabled = false }
    }

    /// Whether the script keeps `MacroText`'s rules and size limit, so it may be run or approved.
    public var canRun: Bool {
        script.utf8.count <= MacroLimits.scriptBytes && MacroText.allows(script)
    }

    /// Breaks that would join words when removed: shown as spaces.
    private static let breaks: Set<Unicode.Scalar> = ["\t", "\n", "\r", "\u{85}", "\u{2028}", "\u{2029}"]

    /// A name as it may be shown: line breaks and tabs as spaces, no other hidden characters,
    /// at most `MacroLimits.nameLength`.
    static func cleanName(_ name: String) -> String {
        var spaced = String.UnicodeScalarView()
        spaced.append(contentsOf: name.unicodeScalars.map { breaks.contains($0) ? " " : $0 })
        return String(SSHErrorClassifier.displayable(String(spaced)).prefix(MacroLimits.nameLength))
    }

    private static func clamp(_ limit: Int, to moment: MacroMoment) -> Int {
        min(max(limit, moment.limitRange.lowerBound), moment.limitRange.upperBound)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, moment, runs, script, isEnabled, timeLimit, stopsSessionOnFailure, approval
    }

    /// Throws only for a missing `id` or `script` or an unknown `moment`; any other field
    /// missing or unreadable takes its moment's default, and a script that can't run is kept
    /// disabled.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys) -> T? {
            (try? container.decodeIfPresent(T.self, forKey: key)) ?? nil
        }
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            name: value(.name) ?? Self.defaultName,
            moment: try container.decode(MacroMoment.self, forKey: .moment),
            runs: value(.runs),
            script: try container.decode(String.self, forKey: .script),
            isEnabled: value(.isEnabled) ?? true,
            timeLimit: value(.timeLimit),
            stopsSessionOnFailure: value(.stopsSessionOnFailure) ?? false,
            approval: value(.approval))
    }
}
