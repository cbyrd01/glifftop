public import Foundation

/// One clipboard per host across the app's windows: which session's offer of which Mac copy
/// each host's clipboard holds, whose offers it supersedes, the fence after an empty offer,
/// and who takes the copy over when its holder ends. Keyed by the destination as typed, each
/// session an opaque id; it never sees a session, a target or clipboard data. Times are
/// `Duration`s since the caller's origin. Only sessions with sharing on take part.
public struct HostClipboardLedger: Sendable {
    /// The sessions that may offer the Mac clipboard to `host` because its holder ended, the
    /// first to ask first.
    public struct Handover: Equatable, Sendable {
        public var host: String
        public var candidates: [UUID]

        public init(host: String, candidates: [UUID]) { (self.host, self.candidates) = (host, candidates) }
    }

    /// How long after a host's empty offer another session's offer to it waits: two channels
    /// may reorder within a few milliseconds.
    public static let fence = Duration.milliseconds(30)

    /// The app is quitting: nothing is handed over.
    public var quitting = false

    private struct Member {
        let host: String
        var sharing: Bool
        /// Registration order: sessions never in front rank after any that has been, the later
        /// registered first.
        let order: Int
        var frontAt: Duration?
        var detaching = false
    }

    private var members: [UUID: Member] = [:]
    private var holders: [String: (session: UUID, changeCount: Int)] = [:]
    private var lastEmpty: [String: Duration] = [:]
    private var registered = 0

    public init() {}

    public mutating func register(_ session: UUID, host: String, sharing: Bool) {
        registered += 1
        members[session] = Member(host: host, sharing: sharing, order: registered)
    }

    /// The session's sharing changed. A holder turning it off hands the copy over, as its end
    /// does (`detaching`).
    @discardableResult
    public mutating func sharing(_ session: UUID, _ on: Bool, macCount: Int) -> [Handover] {
        guard let host = members[session]?.host else { return [] }
        members[session]?.sharing = on
        guard !on, let holder = holders[host], holder.session == session else { return [] }
        holders[host] = nil
        return handover(host, from: holder, macCount: macCount)
    }

    public mutating func front(_ session: UUID, at time: Duration) {
        members[session]?.frontAt = time
    }

    /// Another session to the host holds this Mac copy.
    public func heldElsewhere(_ session: UUID, changeCount: Int) -> Bool {
        guard let host = members[session]?.host, let holder = holders[host] else { return false }
        return holder.session != session && holder.changeCount == changeCount
    }

    /// The session offered the Mac clipboard: it holds the host's clipboard now. Returns the
    /// host's other sessions, whose offers it supersedes, and, inside the fence after the
    /// host's last empty offer, when to send it.
    public mutating func offered(_ session: UUID, changeCount: Int, at time: Duration)
        -> (superseded: [UUID], sendAt: Duration?)
    {
        guard let host = members[session]?.host else { return ([], nil) }
        holders[host] = (session, changeCount)
        let others = members.compactMap {
            $0.key != session && $0.value.host == host && $0.value.sharing ? $0.key : nil
        }
        let sendAt = lastEmpty[host].map { $0 + Self.fence }.flatMap { time < $0 ? $0 : nil }
        return (others, sendAt)
    }

    /// The session withdrew its offer (`empty`: with an empty offer). Returns false for a
    /// detaching session, which sends nothing: its end alone retires its source.
    @discardableResult
    public mutating func withdrew(_ session: UUID, empty: Bool, at time: Duration) -> Bool {
        guard let member = members[session], !member.detaching else { return false }
        release(session, member.host)
        if empty { lastEmpty[member.host] = time }
        return true
    }

    /// The session reported a host copy (not the selection a new server finds, which may
    /// predate the holder's offer). A real copy clears the holder whoever reports it; an empty
    /// one only from the holder's own session, as every other session reports the empty
    /// selection a destroyed source leaves.
    public mutating func hostCopy(_ session: UUID, isFirst: Bool, isEmpty: Bool) {
        guard !isFirst, let host = members[session]?.host else { return }
        if isEmpty { release(session, host) } else { holders[host] = nil }
    }

    /// The sessions are ending together (a window, or every tab of a group). Each host whose
    /// holder is among them, with the Mac clipboard still its copy, hands over to its other
    /// sessions with sharing on, the last in front first; none of `sessions` is a candidate.
    /// The caller asks each in turn until one offers (one may not be allowed to), and that one
    /// becomes the holder through its offer.
    public mutating func detaching(_ sessions: Set<UUID>, macCount: Int) -> [Handover] {
        for session in sessions { members[session]?.detaching = true }
        var handovers: [Handover] = []
        for (host, holder) in holders where sessions.contains(holder.session) {
            holders[host] = nil
            handovers += handover(host, from: holder, macCount: macCount)
        }
        return handovers
    }

    /// The holder of `host`'s clipboard is gone: its copy to the host's other sessions with
    /// sharing on, unless the app quits or the Mac clipboard has moved on.
    private func handover(_ host: String, from holder: (session: UUID, changeCount: Int), macCount: Int)
        -> [Handover]
    {
        let candidates = candidates(host)
        guard !quitting, holder.changeCount == macCount, !candidates.isEmpty else { return [] }
        return [Handover(host: host, candidates: candidates)]
    }

    public mutating func closed(_ session: UUID) {
        guard let member = members.removeValue(forKey: session) else { return }
        release(session, member.host)
    }

    /// The host's clipboard no longer holds the session's offer, if it did.
    private mutating func release(_ session: UUID, _ host: String) {
        if holders[host]?.session == session { holders[host] = nil }
    }

    private func candidates(_ host: String) -> [UUID] {
        members.filter { $0.value.host == host && $0.value.sharing && !$0.value.detaching }
            .sorted { rank($0.value) > rank($1.value) }.map(\.key)
    }

    private func rank(_ member: Member) -> (Int, Duration, Int) {
        (member.frontAt == nil ? 0 : 1, member.frontAt ?? .zero, member.order)
    }
}
