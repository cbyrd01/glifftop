/// When the Mac's clipboard is offered or withdrawn, and when the remote's goes on the Mac: a
/// pure decision the app carries out.
public struct ClipboardPolicy: Sendable {
    /// The Mac clipboard as the app sees it: its `changeCount`, whether it may be offered
    /// (`offerable(typeCount:isPassword:includePasswords:cameFromThisHost:)`), and whether
    /// another window's session to the same host holds this copy
    /// (`HostClipboardLedger.heldElsewhere`).
    public struct MacClipboard: Equatable, Sendable {
        public var changeCount: Int
        public var offerable: Bool
        public var heldElsewhere: Bool

        public init(changeCount: Int, offerable: Bool, heldElsewhere: Bool = false) {
            (self.changeCount, self.offerable, self.heldElsewhere) = (changeCount, offerable, heldElsewhere)
        }
    }

    public enum Event: Equatable, Sendable {
        /// The app came to the front, or left it.
        case front(Bool, MacClipboard)
        case macChanged(MacClipboard)
        case remoteOffer(RemoteClipboardOffer, MacClipboard)
        /// The app put a remote offer on the Mac; the clipboard is now at `changeCount`.
        case wrote(changeCount: Int)
        /// The app's clipboard sharing was turned on or off.
        case sharing(Bool, MacClipboard)
        /// What may be offered changed (whether passwords are shared): our offer the Mac clipboard no
        /// longer allows is withdrawn, in front or not; in front, one it now allows is offered.
        case recheck(MacClipboard)
        /// Another session to the host offered: the host's clipboard is no longer ours, so
        /// nothing of ours is withdrawn there.
        case superseded
        /// The host's holder ended while the Mac clipboard was its copy: this session offers
        /// it, in front or not, so the host keeps it.
        case handOver(MacClipboard)
    }

    /// Whether a Mac copy may be offered: it has types to forward, a password manager's
    /// (concealed or transient) only while passwords are shared, and never one this host's own
    /// session put on the Mac (no echo back to its source; another host's is offered, as a Mac
    /// copy). Offered, it carries KDE's password hint.
    public static func offerable(
        typeCount: Int, isPassword: Bool, includePasswords: Bool, cameFromThisHost: Bool
    ) -> Bool {
        typeCount > 0 && (!isPassword || includePasswords) && !cameFromThisHost
    }

    public enum Action: Equatable, Sendable {
        case offerMac(changeCount: Int)
        case revokeMac(sendEmpty: Bool)
        case putOnMac(RemoteClipboardOffer)
        /// Take what Glifftop put on the Mac clipboard off it.
        case clearOwned
    }

    private var sharing: Bool
    private var front = false
    /// The Mac `changeCount` last offered or withdrawn in front: not offered twice.
    private var seen: Int?
    /// Our offer stands (the host may read it).
    private var live = false
    /// The host's clipboard is still ours: an empty offer may replace it.
    private var hostHasOurs = false
    /// The Mac `changeCount` right after we put a remote offer there (the loop guard).
    private var owned: Int?
    /// The Mac `changeCount` judged in front but not offerable, and still newer than the host's
    /// clipboard: a recheck or the front offers it once it may be.
    private var withheld: Int?
    /// A remote offer that came while away, and the Mac's `changeCount` then.
    private var held: (offer: RemoteClipboardOffer, changeCount: Int)?
    /// The Mac `changeCount` when the host last copied something: a Mac copy at that count is
    /// older than the host's, and isn't handed over onto it.
    private var hostCopied: Int?

    public init(sharing: Bool) { self.sharing = sharing }

    public mutating func handle(_ event: Event) -> [Action] {
        switch event {
        case .front(let isFront, let mac):
            front = isFront
            guard isFront, sharing else { return [] }
            if let held {
                self.held = nil
                if held.changeCount == mac.changeCount {
                    seen = mac.changeCount
                    return [.putOnMac(held.offer)]
                }
            }
            return offerCurrent(mac)
        case .macChanged(let mac):
            guard sharing, mac.changeCount != owned else { return [] }
            if front { return offerCurrent(mac) }
            return withdraw()
        case .remoteOffer(let offer, let mac):
            // The host's clipboard from before the session (upstream reports the selection it
            // finds at start): never put on the Mac, and our offer, made at once, has already
            // replaced it there.
            guard sharing, !offer.isFirst else { return [] }
            hostHasOurs = false
            seen = nil
            (held, withheld) = (nil, nil)
            if offer.hasFiles || !offer.isEmpty { hostCopied = mac.changeCount }
            guard offer.isPasteable else {
                // A copy of nothing the Mac takes (files, which aren't shared; JPEG, RTF)
                // stands on the host: the Mac's clipboard is offered over it only once it
                // changes. A cleared one may be.
                if offer.hasFiles || !offer.isEmpty { seen = mac.changeCount }
                return []
            }
            if front || mac.changeCount == owned { return [.putOnMac(offer)] }
            held = (offer, mac.changeCount)
            return []
        case .wrote(let changeCount):
            owned = changeCount
            seen = changeCount
            withheld = nil
            return withdraw()
        case .sharing(let on, let mac):
            guard on != sharing else { return [] }
            sharing = on
            if on { return front ? offerCurrent(mac) : [] }
            var actions = live || hostHasOurs ? [Action.revokeMac(sendEmpty: hostHasOurs)] : []
            if mac.changeCount == owned { actions.append(.clearOwned) }
            (live, hostHasOurs, seen, owned, held, withheld) = (false, false, nil, nil, nil, nil)
            return actions
        case .recheck(let mac):
            guard sharing else { return [] }
            if live, !mac.offerable {
                // Ours is the host's clipboard still: offered again once allowed.
                if hostHasOurs, mac.changeCount == seen { withheld = mac.changeCount }
                return withdraw()
            }
            return front ? offerCurrent(mac) : []
        case .superseded:
            (live, hostHasOurs, withheld) = (false, false, nil)
            return []
        case .handOver(let mac):
            guard sharing, mac.offerable, mac.changeCount != owned, mac.changeCount != hostCopied else {
                return []
            }
            seen = mac.changeCount
            return offer(mac.changeCount)
        }
    }

    /// In front: offers the Mac clipboard, or withdraws ours if it can't be offered.
    private mutating func offerCurrent(_ mac: MacClipboard) -> [Action] {
        // The host has it from another window: offering it again would make the host fetch it
        // again. Not marked seen: once no window holds it, the front offers it.
        if mac.heldElsewhere { return [] }
        let nowAllowed = mac.offerable && mac.changeCount == withheld
        guard mac.changeCount != seen || nowAllowed, mac.changeCount != owned else { return [] }
        seen = mac.changeCount
        guard mac.offerable else {
            withheld = mac.changeCount
            return withdraw()
        }
        return offer(mac.changeCount)
    }

    /// Offers the Mac clipboard at `changeCount`: ours stands on the host.
    private mutating func offer(_ changeCount: Int) -> [Action] {
        withheld = nil
        (live, hostHasOurs) = (true, true)
        return [.offerMac(changeCount: changeCount)]
    }

    /// Withdraws ours; an empty offer replaces it on the host while the host still holds it (once
    /// sent, there's nothing of ours left there to replace).
    private mutating func withdraw() -> [Action] {
        guard live || hostHasOurs else { return [] }
        defer { (live, hostHasOurs) = (false, false) }
        return [.revokeMac(sendEmpty: hostHasOurs)]
    }
}
