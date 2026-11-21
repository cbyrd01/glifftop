/// Whether a streaming session's link is interrupted: one of the client's Pings has gone
/// unanswered for `answerWithin` and nothing at all, not a byte, has arrived for
/// `silenceLimit`. Bytes count, not messages, so a slow keyframe still arriving keeps the link
/// live; and a Ping just sent can't trip it, so a late tick (App Nap) doesn't either.
///
/// Times are milliseconds of a monotonic clock that stops while the Mac sleeps: a clock step
/// or a wake doesn't look like silence. The session's wall clock is for the wire only.
struct Liveness {
    /// The client pings every 2 s, so a live link is never this quiet.
    static let silenceLimit: UInt64 = 4000
    /// How long a Ping may go unanswered before its silence counts.
    static let answerWithin: UInt64 = 2000

    private var lastHeard: UInt64?
    /// When the oldest Ping sent since the last byte went out.
    private var unansweredSince: UInt64?
    private(set) var isInterrupted = false

    /// Bytes from the server. True when that ends an interruption.
    @discardableResult
    mutating func heard(at now: UInt64) -> Bool {
        lastHeard = now
        unansweredSince = nil
        defer { isInterrupted = false }
        return isInterrupted
    }

    mutating func pinged(at now: UInt64) {
        if unansweredSince == nil { unansweredSince = now }
    }

    /// True when the link has just become interrupted (once per interruption).
    mutating func check(at now: UInt64) -> Bool {
        guard !isInterrupted, let pinged = unansweredSince else { return false }
        let quietSince = lastHeard ?? pinged
        guard now >= pinged + Self.answerWithin, now >= quietSince + Self.silenceLimit else { return false }
        isInterrupted = true
        return true
    }
}
