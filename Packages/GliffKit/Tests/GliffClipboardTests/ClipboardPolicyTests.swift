import GliffClipboard
import Testing

@Suite struct ClipboardPolicyTests {
    private typealias Mac = ClipboardPolicy.MacClipboard

    private let remote = RemoteClipboardOffer(serial: 7, mimeTypes: [ClipboardMimes.text])
    private let newer = RemoteClipboardOffer(serial: 8, mimeTypes: [ClipboardMimes.text])
    private let empty = RemoteClipboardOffer(serial: 9, mimeTypes: [])

    private func mac(_ count: Int, offerable: Bool = true) -> Mac {
        Mac(changeCount: count, offerable: offerable)
    }

    /// A policy in front that has offered Mac clipboard 1.
    private func offering() -> ClipboardPolicy {
        var policy = ClipboardPolicy(sharing: true)
        _ = policy.handle(.front(true, mac(1)))
        return policy
    }

    @Test func comingToTheFrontOffersTheClipboard() {
        var policy = ClipboardPolicy(sharing: true)
        #expect(policy.handle(.front(true, mac(1))) == [.offerMac(changeCount: 1)])
        #expect(policy.handle(.front(false, mac(1))) == [])
        #expect(policy.handle(.front(true, mac(1))) == [])
    }

    @Test func aChangeInFrontIsOffered() {
        var policy = offering()
        #expect(policy.handle(.macChanged(mac(2))) == [.offerMac(changeCount: 2)])
    }

    @Test func aChangeWhileAwayRevokes() {
        var policy = offering()
        _ = policy.handle(.front(false, mac(1)))
        #expect(policy.handle(.macChanged(mac(2))) == [.revokeMac(sendEmpty: true)])
        #expect(policy.handle(.macChanged(mac(3))) == [])
        #expect(policy.handle(.front(true, mac(3))) == [.offerMac(changeCount: 3)])
    }

    @Test func aPasswordInFrontRevokes() {
        var policy = offering()
        #expect(policy.handle(.macChanged(mac(2, offerable: false))) == [.revokeMac(sendEmpty: true)])
        #expect(policy.handle(.front(false, mac(2, offerable: false))) == [])
        #expect(policy.handle(.front(true, mac(2, offerable: false))) == [])
    }

    @Test func aPasswordAfterARemoteOfferRevokesQuietly() {
        var policy = offering()
        #expect(policy.handle(.remoteOffer(remote, mac(1))) == [.putOnMac(remote)])
        #expect(policy.handle(.macChanged(mac(2, offerable: false))) == [.revokeMac(sendEmpty: false)])
    }

    @Test func ourOwnWriteIsNeverOfferedBack() {
        var policy = offering()
        #expect(policy.handle(.remoteOffer(remote, mac(1))) == [.putOnMac(remote)])
        #expect(policy.handle(.wrote(changeCount: 2)) == [.revokeMac(sendEmpty: false)])
        #expect(policy.handle(.macChanged(mac(2))) == [])
        _ = policy.handle(.front(false, mac(2)))
        #expect(policy.handle(.front(true, mac(2))) == [])
    }

    @Test func aRemoteOfferWhileAwayWaitsForTheFront() {
        var policy = offering()
        _ = policy.handle(.front(false, mac(1)))
        #expect(policy.handle(.remoteOffer(remote, mac(1))) == [])
        #expect(policy.handle(.front(true, mac(1))) == [.putOnMac(remote)])
    }

    @Test func aHeldOfferIsDroppedIfTheMacCopiedMeanwhile() {
        var policy = offering()
        _ = policy.handle(.front(false, mac(1)))
        #expect(policy.handle(.remoteOffer(remote, mac(1))) == [])
        #expect(policy.handle(.macChanged(mac(2))) == [.revokeMac(sendEmpty: false)])
        #expect(policy.handle(.front(true, mac(2))) == [.offerMac(changeCount: 2)])
    }

    @Test func aNewerRemoteOfferReplacesOursAtOnceWhileAway() {
        var policy = offering()
        _ = policy.handle(.remoteOffer(remote, mac(1)))
        _ = policy.handle(.wrote(changeCount: 2))
        _ = policy.handle(.front(false, mac(2)))
        #expect(policy.handle(.remoteOffer(newer, mac(2))) == [.putOnMac(newer)])
    }

    @Test func anEmptyRemoteOfferDropsAHeldOne() {
        var policy = offering()
        _ = policy.handle(.front(false, mac(1)))
        #expect(policy.handle(.remoteOffer(remote, mac(1))) == [])
        #expect(policy.handle(.remoteOffer(empty, mac(1))) == [])
        #expect(policy.handle(.front(true, mac(1))) == [.offerMac(changeCount: 1)])
    }

    /// Files aren't shared, but the host's copy of them still stands: the Mac's
    /// unchanged clipboard is not offered over it, a new Mac copy is.
    @Test func aFilesOnlyRemoteOfferIsNotReplacedByTheOldMacClipboard() {
        var policy = offering()
        let files = RemoteClipboardOffer(serial: 9, mimeTypes: [], hasFiles: true)
        #expect(policy.handle(.remoteOffer(files, mac(1))) == [])
        #expect(policy.handle(.front(false, mac(1))) == [])
        #expect(policy.handle(.front(true, mac(1))) == [])
        #expect(policy.handle(.macChanged(mac(2))) == [.offerMac(changeCount: 2)])
    }

    @Test func aFilesOnlyRemoteOfferWhileAwayKeepsTheOldMacClipboardBack() {
        var policy = offering()
        _ = policy.handle(.front(false, mac(1)))
        let files = RemoteClipboardOffer(serial: 9, mimeTypes: [], hasFiles: true)
        #expect(policy.handle(.remoteOffer(files, mac(1))) == [])
        #expect(policy.handle(.front(true, mac(1))) == [])
    }

    /// A host copy of only types the Mac can't take (JPEG, RTF) stands on the host as files do:
    /// nothing goes on the Mac, and the Mac's unchanged clipboard isn't offered over it.
    @Test func aRemoteOfferOfOtherTypesIsNotReplacedByTheOldMacClipboard() {
        var policy = offering()
        let jpeg = RemoteClipboardOffer(serial: 9, mimeTypes: ["image/jpeg", "text/rtf"])
        #expect(policy.handle(.remoteOffer(jpeg, mac(1))) == [])
        #expect(policy.handle(.front(false, mac(1))) == [])
        #expect(policy.handle(.front(true, mac(1))) == [])
        #expect(policy.handle(.macChanged(mac(2))) == [.offerMac(changeCount: 2)])
    }

    @Test func aRemoteOfferOfOtherTypesWhileAwayIsNotHeld() {
        var policy = offering()
        _ = policy.handle(.front(false, mac(1)))
        let jpeg = RemoteClipboardOffer(serial: 9, mimeTypes: ["image/jpeg"])
        #expect(policy.handle(.remoteOffer(jpeg, mac(1))) == [])
        #expect(policy.handle(.front(true, mac(1))) == [])
    }

    /// At connect the server reports the host's clipboard from before; our offer, made at once,
    /// has replaced it there already, so it stands. A later host copy is a real one.
    @Test func theHostsClipboardFromBeforeConnectDoesNotReplaceOurOffer() {
        var policy = offering()
        let before = RemoteClipboardOffer(serial: 1, mimeTypes: [ClipboardMimes.text], isFirst: true)
        #expect(policy.handle(.remoteOffer(before, mac(1))) == [])
        // Ours is still the host's: a Mac change while away replaces it with an empty offer.
        #expect(policy.handle(.front(false, mac(1))) == [])
        #expect(policy.handle(.macChanged(mac(2))) == [.revokeMac(sendEmpty: true)])
        _ = policy.handle(.front(true, mac(2)))
        #expect(policy.handle(.remoteOffer(newer, mac(2))) == [.putOnMac(newer)])
    }

    /// Even with no offer of ours standing, the host's clipboard from before the session never
    /// comes to the Mac (a copy from an earlier session mustn't come back); a host copy
    /// made during it does.
    @Test func theHostsClipboardFromBeforeNeverComesToTheMac() {
        var policy = ClipboardPolicy(sharing: true)
        _ = policy.handle(.front(true, mac(1, offerable: false)))
        let before = RemoteClipboardOffer(serial: 1, mimeTypes: [ClipboardMimes.text], isFirst: true)
        #expect(policy.handle(.remoteOffer(before, mac(1))) == [])
        #expect(policy.handle(.remoteOffer(newer, mac(1))) == [.putOnMac(newer)])
    }

    @Test func anEmptyRemoteOfferInFrontPutsNothingOnTheMac() {
        var policy = offering()
        #expect(policy.handle(.remoteOffer(empty, mac(1))) == [])
    }

    @Test func sharingOffSendsAnEmptyOfferAndStopsEverything() {
        var policy = offering()
        #expect(policy.handle(.sharing(false, mac(1))) == [.revokeMac(sendEmpty: true)])
        #expect(policy.handle(.remoteOffer(remote, mac(1))) == [])
        #expect(policy.handle(.macChanged(mac(2))) == [])
        #expect(policy.handle(.front(true, mac(2))) == [])
        #expect(policy.handle(.sharing(true, mac(2))) == [.offerMac(changeCount: 2)])
    }

    @Test func sharingOffClearsWhatWeWrote() {
        var policy = offering()
        _ = policy.handle(.remoteOffer(remote, mac(1)))
        _ = policy.handle(.wrote(changeCount: 2))
        #expect(policy.handle(.sharing(false, mac(2))) == [.clearOwned])
    }

    @Test func sharingOffDropsAHeldOffer() {
        var policy = offering()
        _ = policy.handle(.front(false, mac(1)))
        _ = policy.handle(.remoteOffer(remote, mac(1)))
        _ = policy.handle(.sharing(false, mac(1)))
        _ = policy.handle(.sharing(true, mac(1)))
        #expect(policy.handle(.front(true, mac(1))) == [.offerMac(changeCount: 1)])
    }

    @Test func nothingIsSentForAChangeBeforeAnyOffer() {
        var policy = ClipboardPolicy(sharing: true)
        #expect(policy.handle(.macChanged(mac(2))) == [])
    }

    /// A copy with types to offer is offered; a password manager's only while passwords are shared.
    @Test func aPasswordIsNotOfferableUnlessIncluded() {
        #expect(ClipboardPolicy.offerable(typeCount: 1, isPassword: false, includePasswords: false))
        #expect(ClipboardPolicy.offerable(typeCount: 1, isPassword: false, includePasswords: true))
        #expect(!ClipboardPolicy.offerable(typeCount: 1, isPassword: true, includePasswords: false))
        #expect(ClipboardPolicy.offerable(typeCount: 1, isPassword: true, includePasswords: true))
        #expect(!ClipboardPolicy.offerable(typeCount: 0, isPassword: false, includePasswords: true))
        #expect(!ClipboardPolicy.offerable(typeCount: 0, isPassword: true, includePasswords: true))
    }

    /// Passwords no longer shared: a password offered is withdrawn, as a Mac change would; on
    /// again, it is offered again.
    @Test func aRecheckWithdrawsWhatIsNoLongerOfferable() {
        var policy = offering()
        #expect(policy.handle(.recheck(mac(1, offerable: false))) == [.revokeMac(sendEmpty: true)])
        #expect(policy.handle(.recheck(mac(1, offerable: false))) == [])
        #expect(policy.handle(.recheck(mac(1))) == [.offerMac(changeCount: 1)])
    }

    @Test func aRecheckOffersWhatNowIs() {
        var policy = offering()
        #expect(policy.handle(.macChanged(mac(2, offerable: false))) == [.revokeMac(sendEmpty: true)])
        #expect(policy.handle(.recheck(mac(2))) == [.offerMac(changeCount: 2)])
        #expect(policy.handle(.recheck(mac(2))) == [])
    }

    /// Away, nothing is offered: what a recheck now allows waits for the front.
    @Test func aRecheckAwayOrNotSharingDoesNothing() {
        var off = ClipboardPolicy(sharing: false)
        _ = off.handle(.front(true, mac(1, offerable: false)))
        #expect(off.handle(.recheck(mac(1))) == [])

        var policy = offering()
        #expect(policy.handle(.macChanged(mac(2, offerable: false))) == [.revokeMac(sendEmpty: true)])
        _ = policy.handle(.front(false, mac(2, offerable: false)))
        #expect(policy.handle(.recheck(mac(2))) == [])
        #expect(policy.handle(.front(true, mac(2))) == [.offerMac(changeCount: 2)])
    }

    /// Settings takes the front from the session's window: no longer sharing passwords there
    /// still withdraws the password the host could read.
    @Test func aRecheckWithdrawsEvenAway() {
        var policy = offering()
        _ = policy.handle(.front(false, mac(1)))
        #expect(policy.handle(.recheck(mac(1, offerable: false))) == [.revokeMac(sendEmpty: true)])
        #expect(policy.handle(.front(true, mac(1, offerable: false))) == [])
    }

    /// A host copy newer than the Mac's withheld one stands: a recheck doesn't offer over it.
    @Test func aRecheckDoesNotOfferOverTheHostsNewerCopy() {
        var policy = offering()
        #expect(policy.handle(.macChanged(mac(2, offerable: false))) == [.revokeMac(sendEmpty: true)])
        let jpeg = RemoteClipboardOffer(serial: 9, mimeTypes: ["image/jpeg"])
        #expect(policy.handle(.remoteOffer(jpeg, mac(2, offerable: false))) == [])
        #expect(policy.handle(.recheck(mac(2))) == [])
    }

    /// Our offer still live but the host has copied since: withdrawn on a recheck, and never
    /// offered again over the host's copy.
    @Test func aRecheckNeverRestoresOursOverTheHostsNewerCopy() {
        var policy = offering()
        let jpeg = RemoteClipboardOffer(serial: 9, mimeTypes: ["image/jpeg"])
        #expect(policy.handle(.remoteOffer(jpeg, mac(1))) == [])
        #expect(policy.handle(.recheck(mac(1, offerable: false))) == [.revokeMac(sendEmpty: false)])
        #expect(policy.handle(.recheck(mac(1))) == [])
        #expect(policy.handle(.front(false, mac(1))) == [])
        #expect(policy.handle(.front(true, mac(1))) == [])
    }
}
