import GliffClipboard
import Testing

/// The policy's side of one clipboard per host: a copy another window to the host holds,
/// an offer superseded by another window's, and the handover when the holder ends.
@Suite struct ClipboardPolicyHostTests {
    private typealias Mac = ClipboardPolicy.MacClipboard

    private func mac(_ count: Int, offerable: Bool = true, heldElsewhere: Bool = false) -> Mac {
        Mac(changeCount: count, offerable: offerable, heldElsewhere: heldElsewhere)
    }

    /// Another window to the host offered this copy: coming to the front doesn't offer it
    /// again (the host would fetch it again).
    @Test func aHeldCopyIsNotOfferedInFront() {
        var policy = ClipboardPolicy(sharing: true)
        #expect(policy.handle(.front(true, mac(1, heldElsewhere: true))) == [])
        _ = policy.handle(.front(false, mac(1, heldElsewhere: true)))
        #expect(policy.handle(.front(true, mac(1, heldElsewhere: true))) == [])
    }

    /// Once no other window holds it (its holder gone with no handover), the front offers it.
    @Test func aCopyNoLongerHeldIsOfferedInFront() {
        var policy = ClipboardPolicy(sharing: true)
        _ = policy.handle(.front(true, mac(1, heldElsewhere: true)))
        _ = policy.handle(.front(false, mac(1)))
        #expect(policy.handle(.front(true, mac(1))) == [.offerMac(changeCount: 1)])
    }

    /// A host copy reported while another window held ours: the stale Mac copy isn't offered
    /// over it once that holder is gone.
    @Test func aHostCopyAfterAHeldOneIsNotOfferedOver() {
        var policy = ClipboardPolicy(sharing: true)
        let copy = RemoteClipboardOffer(serial: 1, mimeTypes: [ClipboardMimes.text])
        _ = policy.handle(.front(true, mac(1, heldElsewhere: true)))
        _ = policy.handle(.front(false, mac(1)))
        _ = policy.handle(.remoteOffer(copy, mac(1)))
        #expect(policy.handle(.front(true, mac(1))) == [.putOnMac(copy)])
    }

    /// The host copied after the Mac did: the handed-over Mac copy would replace a newer one.
    @Test func aHandOverAfterAHostCopyOffersNothing() {
        var policy = ClipboardPolicy(sharing: true)
        _ = policy.handle(
            .remoteOffer(RemoteClipboardOffer(serial: 1, mimeTypes: [ClipboardMimes.text]), mac(5)))
        #expect(policy.handle(.handOver(mac(5))) == [])
    }

    /// The empty selection the ending holder's source leaves is no newer copy.
    @Test func aHandOverAfterAnEmptyHostReportOffers() {
        var policy = ClipboardPolicy(sharing: true)
        _ = policy.handle(.remoteOffer(RemoteClipboardOffer(serial: 1, mimeTypes: []), mac(5)))
        #expect(policy.handle(.handOver(mac(5))) == [.offerMac(changeCount: 5)])
    }

    /// Superseded, what was withheld is forgotten too: a later recheck in front offers nothing.
    @Test func aSupersededSessionForgetsWhatItWithheld() {
        var policy = ClipboardPolicy(sharing: true)
        _ = policy.handle(.front(true, mac(1, offerable: false)))
        _ = policy.handle(.superseded)
        #expect(policy.handle(.recheck(mac(1))) == [])
    }

    @Test func aNewCopyInFrontIsOffered() {
        var policy = ClipboardPolicy(sharing: true)
        _ = policy.handle(.front(true, mac(1, heldElsewhere: true)))
        #expect(policy.handle(.macChanged(mac(2))) == [.offerMac(changeCount: 2)])
    }

    @Test func handOverOffersOutOfFront() {
        var policy = ClipboardPolicy(sharing: true)
        #expect(policy.handle(.handOver(mac(1))) == [.offerMac(changeCount: 1)])
        // Ours now: a change while away withdraws it with an empty offer.
        #expect(policy.handle(.macChanged(mac(2))) == [.revokeMac(sendEmpty: true)])
    }

    @Test func handOverWithSharingOffOffersNothing() {
        var policy = ClipboardPolicy(sharing: false)
        #expect(policy.handle(.handOver(mac(1))) == [])
    }

    @Test func handOverOfAPasswordNotSharedOffersNothing() {
        var policy = ClipboardPolicy(sharing: true)
        #expect(policy.handle(.handOver(mac(1, offerable: false))) == [])
    }

    @Test func handOverOfTheHostsOwnCopyOffersNothing() {
        var policy = ClipboardPolicy(sharing: true)
        _ = policy.handle(.wrote(changeCount: 1))
        #expect(policy.handle(.handOver(mac(1))) == [])
    }

    /// Another window's offer replaced ours on the host: a later change away from the front
    /// sends no empty offer, which would clear that window's.
    @Test func aSupersededSessionSendsNoEmptyOffer() {
        var policy = ClipboardPolicy(sharing: true)
        #expect(policy.handle(.front(true, mac(1))) == [.offerMac(changeCount: 1)])
        #expect(policy.handle(.superseded) == [])
        _ = policy.handle(.front(false, mac(1)))
        #expect(policy.handle(.macChanged(mac(2))) == [])
    }
}
