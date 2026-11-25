import Foundation
import GliffClipboard
import Testing

/// One clipboard per host across its windows: who holds the host's clipboard, who is told
/// their offer is superseded, the fence after an empty offer, and the handover when the holder
/// ends.
@Suite struct HostClipboardLedgerTests {
    private let a = UUID(), b = UUID(), c = UUID(), d = UUID()

    private func ms(_ value: Int) -> Duration { .milliseconds(value) }

    /// A, B and C to omarchy, D to another host, all sharing.
    private func ledger() -> HostClipboardLedger {
        var ledger = HostClipboardLedger()
        for session in [a, b, c] { ledger.register(session, host: "omarchy", sharing: true) }
        ledger.register(d, host: "box", sharing: true)
        return ledger
    }

    @Test func anOfferMakesTheHolder() {
        var ledger = ledger()
        _ = ledger.offered(a, changeCount: 5, at: ms(0))
        #expect(ledger.heldElsewhere(b, changeCount: 5))
        #expect(!ledger.heldElsewhere(a, changeCount: 5))
        #expect(!ledger.heldElsewhere(b, changeCount: 6))
        #expect(!ledger.heldElsewhere(d, changeCount: 5))
    }

    @Test func onlyTheHoldersWithdrawalClearsIt() {
        var ledger = ledger()
        _ = ledger.offered(a, changeCount: 5, at: ms(0))
        ledger.withdrew(b, empty: false, at: ms(1))
        #expect(ledger.heldElsewhere(b, changeCount: 5))
        ledger.withdrew(a, empty: false, at: ms(2))
        #expect(!ledger.heldElsewhere(b, changeCount: 5))
    }

    @Test func theHoldersOwnHostCopyClearsIt() {
        var ledger = ledger()
        _ = ledger.offered(a, changeCount: 5, at: ms(0))
        ledger.hostCopy(a, isFirst: false, isEmpty: true)
        #expect(!ledger.heldElsewhere(b, changeCount: 5))
    }

    /// A new session's report of the selection it finds at start may predate the holder's offer.
    @Test func anotherSessionsFirstReportKeepsTheHolder() {
        var ledger = ledger()
        _ = ledger.offered(a, changeCount: 5, at: ms(0))
        ledger.hostCopy(b, isFirst: true, isEmpty: false)
        ledger.hostCopy(a, isFirst: true, isEmpty: false)
        #expect(ledger.heldElsewhere(b, changeCount: 5))
    }

    /// Every other session reports the empty selection a destroyed source leaves.
    @Test func anotherSessionsEmptyReportKeepsTheHolder() {
        var ledger = ledger()
        _ = ledger.offered(a, changeCount: 5, at: ms(0))
        ledger.hostCopy(b, isFirst: false, isEmpty: true)
        #expect(ledger.heldElsewhere(c, changeCount: 5))
    }

    /// A real host copy, whichever session reports it: the holder's report may never come (its
    /// link down).
    @Test func anotherSessionsRealHostCopyClearsTheHolder() {
        var ledger = ledger()
        _ = ledger.offered(a, changeCount: 5, at: ms(0))
        ledger.hostCopy(b, isFirst: false, isEmpty: false)
        #expect(!ledger.heldElsewhere(c, changeCount: 5))
    }

    /// The holder turning sharing off hands the copy over, as its end does.
    @Test func aHolderTurningSharingOffHandsOver() {
        var ledger = ledger()
        _ = ledger.offered(a, changeCount: 5, at: ms(0))
        let handovers = ledger.sharing(a, false, macCount: 5)
        #expect(handovers == [.init(host: "omarchy", candidates: [c, b])])
        #expect(!ledger.heldElsewhere(b, changeCount: 5))
    }

    @Test func aNonHolderTurningSharingOffHandsOverNothing() {
        var ledger = ledger()
        _ = ledger.offered(a, changeCount: 5, at: ms(0))
        let handovers = ledger.sharing(b, false, macCount: 5)
        #expect(handovers == [])
        #expect(ledger.heldElsewhere(c, changeCount: 5))
    }

    @Test func anOfferSupersedesTheHostsOtherSessions() {
        var ledger = ledger()
        let result = ledger.offered(b, changeCount: 5, at: ms(0))
        #expect(Set(result.superseded) == [a, c])
        #expect(result.sendAt == nil)
    }

    @Test func anOfferInsideTheFenceWaits() {
        var ledger = ledger()
        ledger.withdrew(a, empty: true, at: ms(0))
        let offer = ledger.offered(b, changeCount: 6, at: ms(5))
        #expect(offer.sendAt == ms(30))
    }

    @Test func anOfferAfterTheFenceGoesAtOnce() {
        var ledger = ledger()
        ledger.withdrew(a, empty: true, at: ms(0))
        let offer = ledger.offered(b, changeCount: 6, at: ms(30))
        #expect(offer.sendAt == nil)
    }

    @Test func theFenceIsPerHost() {
        var ledger = ledger()
        ledger.withdrew(a, empty: true, at: ms(0))
        let offer = ledger.offered(d, changeCount: 6, at: ms(5))
        #expect(offer.sendAt == nil)
    }

    @Test func theHolderEndingHandsOverToTheLastInFrontFirst() {
        var ledger = ledger()
        ledger.front(c, at: ms(1))
        ledger.front(b, at: ms(2))
        ledger.front(a, at: ms(3))
        _ = ledger.offered(a, changeCount: 5, at: ms(3))
        let handovers = ledger.detaching([a], macCount: 5)
        #expect(handovers == [.init(host: "omarchy", candidates: [b, c])])
        #expect(!ledger.heldElsewhere(b, changeCount: 5))
    }

    /// Never in front: the later registered first.
    @Test func aNeverFrontSessionOrdersByRegistration() {
        var ledger = ledger()
        _ = ledger.offered(a, changeCount: 5, at: ms(0))
        let handovers = ledger.detaching([a], macCount: 5)
        #expect(handovers == [.init(host: "omarchy", candidates: [c, b])])
    }

    @Test func aSessionOnceInFrontRanksAboveNeverFrontOnes() {
        var ledger = ledger()
        ledger.front(b, at: ms(1))
        _ = ledger.offered(a, changeCount: 5, at: ms(2))
        let handovers = ledger.detaching([a], macCount: 5)
        #expect(handovers == [.init(host: "omarchy", candidates: [b, c])])
    }

    @Test func aSessionWithSharingOffIsNoTarget() {
        var ledger = ledger()
        ledger.front(b, at: ms(1))
        _ = ledger.sharing(b, false, macCount: 5)
        _ = ledger.offered(a, changeCount: 5, at: ms(2))
        let handovers = ledger.detaching([a], macCount: 5)
        #expect(handovers == [.init(host: "omarchy", candidates: [c])])
    }

    /// ⇧⌘W tells the ledger every tab of the group first: none is a target.
    @Test func aGroupClosingTogetherHandsNothingWithin() {
        var ledger = ledger()
        _ = ledger.offered(a, changeCount: 5, at: ms(0))
        let handovers = ledger.detaching([a, b, c], macCount: 5)
        #expect(handovers == [])
        ledger.closed(a)
        let later = ledger.detaching([b], macCount: 5)
        #expect(later == [])
    }

    @Test func aGroupOfTwoHostsHandsOverOnEach() {
        var ledger = ledger()
        let e = UUID()
        ledger.register(e, host: "box", sharing: true)
        _ = ledger.offered(a, changeCount: 5, at: ms(0))
        _ = ledger.offered(d, changeCount: 5, at: ms(0))
        let handovers = ledger.detaching([a, d], macCount: 5)
        #expect(Set(handovers.compactMap(\.candidates.first)) == [c, e])
    }

    @Test func aNonHolderEndingHandsOverNothing() {
        var ledger = ledger()
        _ = ledger.offered(a, changeCount: 5, at: ms(0))
        let handovers = ledger.detaching([b], macCount: 5)
        #expect(handovers == [])
        #expect(ledger.heldElsewhere(c, changeCount: 5))
    }

    /// The Mac clipboard moved on: the held copy is stale, nothing to hand over.
    @Test func aChangedMacCountHandsOverNothing() {
        var ledger = ledger()
        _ = ledger.offered(a, changeCount: 5, at: ms(0))
        let handovers = ledger.detaching([a], macCount: 6)
        #expect(handovers == [])
    }

    /// The detaching holder's end alone retires its source: no empty offer from it, and so no
    /// fence for the new holder's offer.
    @Test func aHandingOverHolderSendsNothing() {
        var ledger = ledger()
        _ = ledger.offered(a, changeCount: 5, at: ms(0))
        let handovers = ledger.detaching([a], macCount: 5)
        #expect(handovers.count == 1)
        let sent = ledger.withdrew(a, empty: true, at: ms(1))
        #expect(!sent)
        let offer = ledger.offered(c, changeCount: 5, at: ms(2))
        #expect(offer.sendAt == nil)
    }

    @Test func nothingIsHandedOverWhileQuitting() {
        var ledger = ledger()
        _ = ledger.offered(a, changeCount: 5, at: ms(0))
        ledger.quitting = true
        let handovers = ledger.detaching([a], macCount: 5)
        #expect(handovers == [])
    }

    @Test func aClosedSessionIsForgotten() {
        var ledger = ledger()
        _ = ledger.offered(a, changeCount: 5, at: ms(0))
        ledger.closed(a)
        #expect(!ledger.heldElsewhere(b, changeCount: 5))
        let offer = ledger.offered(b, changeCount: 6, at: ms(1))
        #expect(!offer.superseded.contains(a))
    }
}
