public import GliffTransport

/// Why a run never started its script.
public enum NotStartedKind: Equatable, Sendable {
    /// No connection to the host: the sign-in failed, or the connection was lost first.
    case noConnection
    /// The connection had no room, and the run may not open one.
    case connectionFull
    /// The host refused the channel.
    case refused
    /// The host ran something other than the wrapper (a forced command).
    case ranSomethingElse
    /// The script can't run (`Macro.canRun`).
    case cannotRun
}

/// How a run ended (spec 4.5). The words are fixed: none carries text from the host, its output
/// or ssh's stderr.
public enum MacroResult: Equatable, Sendable {
    /// The trailer `exit N`.
    case exited(Int32)
    /// The trailer `timeout`, or no trailer by the Mac's deadline; `seconds` is the limit.
    case timedOut(seconds: Int)
    /// 4 MiB of output arrived before the trailer.
    case outputTooLarge
    /// Status 125: the wrapper didn't get the whole text.
    case notReceived
    /// Status 126: the host has no `head`.
    case noHead
    /// The start line arrived, then the channel ended without a trailer.
    case endedWhileRunning
    case notStarted(NotStartedKind)
    /// Cancelled: the person, a Disconnect, a new connection, closing or quitting.
    case stopped
    /// Skipped: not approved.
    case notApproved
    /// The host named the screen in a way Glifftop doesn't pass on.
    case badOutputName

    public var words: String {
        switch self {
        case .exited(let status): "exit \(status)"
        case .timedOut(let seconds): "Timed out after \(seconds) s"
        case .outputTooLarge: "Stopped: more than 4 MiB of output"
        case .notReceived:
            "The host didn't get the whole macro (a login file that reads input, or a forced command, can cause this)"
        case .noHead: "The host has no head command"
        case .endedWhileRunning: "The connection ended while the macro ran"
        case .notStarted(let kind): "Not run: " + kind.words
        case .stopped: "Stopped"
        case .notApproved: "Not run: not approved"
        case .badOutputName: "The host named the screen in a way Glifftop doesn't pass on"
        }
    }

    /// Only `exit 0` is a success.
    public var isSuccess: Bool { self == .exited(0) }

    /// Whether "Stop the session if this fails" counts this as a failure: every result but a
    /// success, a cancel and Don't Run.
    public var countsAsFailure: Bool {
        switch self {
        case .stopped, .notApproved: false
        default: !isSuccess
        }
    }
}

extension NotStartedKind {
    var words: String {
        switch self {
        case .noConnection: "no connection to the host"
        case .connectionFull: "the connection to the host is full"
        case .refused: "the host refused it"
        case .ranSomethingElse: "the host ran something else"
        case .cannotRun: "the script can't run"
        }
    }
}

/// One finished run.
public struct MacroRun: Sendable {
    public let result: MacroResult
    public let duration: Duration
    /// The script's output, its first `MacroOutput.keptLimit` bytes.
    public let output: [UInt8]
    /// Output bytes past the cap, counted, not kept.
    public let droppedBytes: Int
    /// The channel's own failure, when it kept the run from starting (no connection, a full
    /// one, or a refusal): a `before` run passes the sign-in's failure on.
    public let channelError: TransportError?

    public init(
        result: MacroResult, duration: Duration, output: [UInt8] = [], droppedBytes: Int = 0,
        channelError: TransportError? = nil
    ) {
        (self.result, self.duration, self.output) = (result, duration, output)
        (self.droppedBytes, self.channelError) = (droppedBytes, channelError)
    }
}
