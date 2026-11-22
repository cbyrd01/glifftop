/// Whether a streaming session's link is interrupted: one of the client's Pings has gone
/// unanswered for `answerWithin` and nothing at all, not a byte, has arrived for
/// `silenceLimit`. Bytes count, not messages, so a slow keyframe still arriving keeps the link
/// live; and a Ping just sent can't trip it, so a late tick (App Nap) doesn't either.
///
/// Times are milliseconds of a monotonic clock that stops while the Mac sleeps: a clock step
/// or a wake doesn't look like silence. The session's wall clock is for the wire only.
///
/// It also holds the probe after a wake (`probe(ping:at:)`), which, unanswered, ends the
/// session: a link that died while the Mac slept would otherwise look live for a while.
struct Liveness {
    /// The client pings every 2 s, so a live link is never this quiet.
    static let silenceLimit: UInt64 = 4000
    /// How long a Ping may go unanswered before its silence counts.
    static let answerWithin: UInt64 = 2000

    /// How long a probe's Ping (`probe(ping:at:)`) may go unanswered before the link counts
    /// as lost.
    static let probeLimit: UInt64 = 3000

    private var lastHeard: UInt64?
    /// The probe now waiting: its Ping's `t`, and when it was sent.
    private var probing: (ping: UInt64, at: UInt64)?
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

    /// A probe (after a wake): the link is lost unless the Pong to Ping `t` arrives within
    /// `probeLimit`. Any other byte may have been on its way before the Mac slept. A new probe
    /// replaces the one waiting.
    mutating func probe(ping t: UInt64, at now: UInt64) {
        probing = (t, now)
    }

    /// A Pong to Ping `t` arrived.
    mutating func answered(ping t: UInt64) {
        if probing?.ping == t { probing = nil }
    }

    /// True when a probe has gone unanswered for `probeLimit` (once per probe).
    mutating func probeFailed(at now: UInt64) -> Bool {
        guard let probing, now >= probing.at + Self.probeLimit else { return false }
        self.probing = nil
        return true
    }
}
