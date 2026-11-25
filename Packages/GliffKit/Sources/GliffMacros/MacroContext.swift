public import GliffTransport

/// Why a run's environment can't be built: the run doesn't happen.
public enum MacroContextError: Error, Equatable, Sendable {
    /// The host named the screen in a way Glifftop doesn't pass on.
    case badOutputName
    /// The chosen monitor's name isn't one Get Screens could offer.
    case badMonitorName
}

/// What a run tells its script, as `GLIFF_*` variables: the moment, whether this is a
/// reconnect's try, the screen chosen and, once the session exists, the server's output.
/// Nothing else: never the machine's name, its destination, the user or the clipboard.
public struct MacroContext: Sendable {
    /// What the preview shows for the output's name before a session names it.
    public static let outputPlaceholder = "(the screen's name)"

    /// Every variable `exports` may name. The prelude unsets them all first, so a value from the
    /// host's own environment never stands in for one this run doesn't set.
    static let variables = [
        "GLIFF_MOMENT", "GLIFF_RECONNECT", "GLIFF_SCREEN", "GLIFF_MONITOR", "GLIFF_OUTPUT", "GLIFF_HEADLESS",
    ]

    public let moment: MacroMoment
    public let reconnecting: Bool
    public let screen: ScreenChoice
    /// The server's output name, from HelloAck; nil for `before`, when no session exists.
    public let output: String?
    /// Whether the session shows a virtual screen, from HelloAck; nil as `output` is.
    public let headless: Bool?

    /// Each name is checked as Get Screens checks one (`ScreenListParser.isValidName`). A
    /// `before` run has no session: `output` and `headless` are dropped, not checked.
    public init(
        moment: MacroMoment, reconnecting: Bool, screen: ScreenChoice, output: String? = nil,
        headless: Bool? = nil
    ) throws(MacroContextError) {
        if case .named(let name) = screen, !ScreenChoice.isMonitorName(name) {
            throw .badMonitorName
        }
        self.init(unchecked: moment, reconnecting, screen, output, headless)
        if let output = self.output, !ScreenListParser.isValidName(output) { throw .badOutputName }
    }

    private init(
        unchecked moment: MacroMoment, _ reconnecting: Bool, _ screen: ScreenChoice, _ output: String?,
        _ headless: Bool?
    ) {
        (self.moment, self.reconnecting, self.screen) = (moment, reconnecting, screen)
        let session = moment != .before
        (self.output, self.headless) = (session ? output : nil, session ? headless : nil)
    }

    /// The context the editor and the approval sheet show, with sample values: a first try
    /// (`GLIFF_RECONNECT=0`), the output's name, not known yet, as `outputPlaceholder`, and
    /// `GLIFF_HEADLESS` from `screen`. A run's own values can differ in these.
    public static func preview(for moment: MacroMoment, screen: ScreenChoice) -> MacroContext {
        MacroContext(unchecked: moment, false, screen, outputPlaceholder, screen == .virtual)
    }

    /// The variables the prelude exports, in order, values unquoted (spec 3.5's table).
    public var exports: [(name: String, value: String)] {
        var exports = [
            ("GLIFF_MOMENT", moment.rawValue), ("GLIFF_RECONNECT", reconnecting ? "1" : "0"),
        ]
        switch screen {
        case .focused: exports.append(("GLIFF_SCREEN", "focused"))
        case .virtual: exports.append(("GLIFF_SCREEN", "virtual"))
        case .named(let name): exports += [("GLIFF_SCREEN", "monitor"), ("GLIFF_MONITOR", name)]
        }
        if let output { exports.append(("GLIFF_OUTPUT", output)) }
        if let headless { exports.append(("GLIFF_HEADLESS", headless ? "1" : "0")) }
        return exports
    }
}
