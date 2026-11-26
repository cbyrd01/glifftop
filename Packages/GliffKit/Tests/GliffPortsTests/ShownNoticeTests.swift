import Testing

@testable import GliffPorts

/// The one notice a window shows, and whether it just came (the picture's capsule).
@Suite struct ShownNoticeTests {
    private let forwarded = PortNotice.forwarded(id: ForwardID(value: 2), remote: 8080, local: 8080)
    private let moved = PortNotice.moved(id: ForwardID(value: 1), remote: 5173, from: 5173, to: 5174)

    private func snapshot(_ notices: [PortNotice]) -> PortsSnapshot {
        var snapshot = PortsSnapshot()
        snapshot.notices = notices
        return snapshot
    }

    /// The last that came is shown, whatever the notices' order.
    @Test func theNewestIsShownWhateverTheOrder() {
        let shown = snapshot([moved, forwarded]).shownNotice(since: snapshot([forwarded]), shown: forwarded)
        #expect(shown == ShownNotice(notice: moved, isNew: true))
    }

    /// One answered or gone gives way to the last one left, which isn't new.
    @Test func anAnsweredNoticeGivesWayToAnOlderOne() {
        let offer = PortNotice.listening(port: 3000, name: nil)
        let shown = snapshot([forwarded]).shownNotice(since: snapshot([forwarded, offer]), shown: offer)
        #expect(shown == ShownNotice(notice: forwarded, isNew: false))
        let kept = snapshot([moved, forwarded]).shownNotice(
            since: snapshot([moved, forwarded]), shown: moved)
        #expect(kept == ShownNotice(notice: moved, isNew: false))
        let none = snapshot([]).shownNotice(since: snapshot([moved]), shown: moved)
        #expect(none == ShownNotice(notice: nil, isNew: false))
    }

    /// Fewer offered ports are no new notice; another port is.
    @Test func onlyAnotherPortMakesAnOfferNew() {
        let three = PortNotice.several(ports: [3000, 3001, 3002])
        let two = PortNotice.several(ports: [3000, 3001])
        let one = PortNotice.listening(port: 3000, name: "node")
        let fewer = snapshot([two]).shownNotice(since: snapshot([three]), shown: three)
        #expect(fewer == ShownNotice(notice: two, isNew: false))
        let last = snapshot([one]).shownNotice(since: snapshot([two]), shown: two)
        #expect(last == ShownNotice(notice: one, isNew: false))
        let more = PortNotice.several(ports: [3000, 4000])
        let another = snapshot([more]).shownNotice(since: snapshot([one]), shown: one)
        #expect(another == ShownNotice(notice: more, isNew: true))
    }

    /// The first snapshot a window has is where it starts: nothing in it is new.
    @Test func aWindowsFirstSnapshotIsNotNew() {
        let first = snapshot([moved, forwarded]).shownNotice(since: nil, shown: nil)
        #expect(first == ShownNotice(notice: forwarded, isNew: false))
    }
}
