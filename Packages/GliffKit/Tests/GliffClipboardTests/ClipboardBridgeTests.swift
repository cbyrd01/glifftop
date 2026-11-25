import Foundation
import GliffProtocol
import GliffTestSupport
import Testing

@testable import GliffClipboard

// A hang names its test within a minute instead of holding the run.
@Suite(.timeLimit(.minutes(1))) struct ClipboardBridgeTests {
    private let text = ClipboardMimes.text
    private func textOffer(token: Int = 1) -> LocalClipboardOffer {
        LocalClipboardOffer(mimeTypes: ClipboardMimes.textFlavours, token: token)
    }

    /// The types alone: no history marker.
    @Test func anOfferIsTheTypesAlone() async {
        let (bridge, wire) = recordedBridge()
        await bridge.offer(textOffer())
        guard case .offer(_, let mimes, let files)? = wire.messages.first else {
            Issue.record("no offer sent")
            return
        }
        #expect(mimes == ClipboardMimes.textFlavours)
        #expect(files.isEmpty)
    }

    /// A password manager's copy goes with KDE's marker, so the host's history doesn't keep it.
    @Test func aPasswordOfferCarriesTheHint() async {
        let (bridge, wire) = recordedBridge()
        await bridge.offer(
            LocalClipboardOffer(mimeTypes: ClipboardMimes.textFlavours, token: 1, isPassword: true))
        guard case .offer(_, let mimes, _)? = wire.messages.first else {
            Issue.record("no offer sent")
            return
        }
        #expect(mimes == ClipboardMimes.textFlavours + [ClipboardMimes.passwordHint])
    }

    @Test func aPasswordsHintIsAnsweredEmpty() async throws {
        let source = FakeLocalSource(bytes: [1, 2, 3])
        let (bridge, wire) = recordedBridge(source)
        await bridge.offer(
            LocalClipboardOffer(mimeTypes: ClipboardMimes.textFlavours, token: 1, isPassword: true))
        let serial = try #require(wire.lastOfferSerial)
        await bridge.receive(
            .request(id: 2, serial: serial, item: .mime(ClipboardMimes.passwordHint)), payload: [])
        await wire.wait { $0.dataCount == 1 }
        #expect(wire.messages.last == .data(id: 2, offset: 0, dataLength: 0, done: true))
        #expect(source.callCount == 0)
    }

    /// The marker is the bridge's to add: listed once, even if the app's types held it.
    @Test func aPasswordOfferListsTheHintOnce() async {
        let (bridge, wire) = recordedBridge()
        let mimes = [text, ClipboardMimes.passwordHint]
        await bridge.offer(LocalClipboardOffer(mimeTypes: mimes, token: 1, isPassword: true))
        await bridge.offer(LocalClipboardOffer(mimeTypes: mimes, token: 2))
        let offered = wire.messages.compactMap { message -> [String]? in
            guard case .offer(_, let mimes, _) = message else { return nil }
            return mimes
        }
        #expect(offered == [[text, ClipboardMimes.passwordHint], [text]])
    }

    /// An empty offer lists no marker: a request for it is refused like any type not offered.
    @Test func theHintOfAnEmptyPasswordOfferIsRefused() async throws {
        let (bridge, wire) = recordedBridge(FakeLocalSource(bytes: [1]))
        await bridge.offer(LocalClipboardOffer(mimeTypes: [], token: 1, isPassword: true))
        let serial = try #require(wire.lastOfferSerial)
        await bridge.receive(
            .request(id: 2, serial: serial, item: .mime(ClipboardMimes.passwordHint)), payload: [])
        await wire.wait { $0.contains(.abort(id: 2)) }
        #expect(wire.dataCount == 0)
    }

    /// No marker was offered: a request for it is a type not offered.
    @Test func theHintOfAnOrdinaryCopyIsRefused() async throws {
        let (bridge, wire) = recordedBridge(FakeLocalSource(bytes: [1]))
        await bridge.offer(textOffer())
        let serial = try #require(wire.lastOfferSerial)
        await bridge.receive(
            .request(id: 2, serial: serial, item: .mime(ClipboardMimes.passwordHint)), payload: [])
        await wire.wait { $0.contains(.abort(id: 2)) }
        #expect(wire.dataCount == 0)
    }

    @Test func anEmptyOfferIsEmpty() async {
        let (bridge, wire) = recordedBridge()
        await bridge.offer(LocalClipboardOffer(mimeTypes: [], token: 1))
        #expect(wire.messages == [.offer(serial: wire.lastOfferSerial ?? 0, mimeTypes: [], files: [])])
    }

    @Test func serialsKeepIncreasingAfterARevoke() async throws {
        let (bridge, wire) = recordedBridge()
        await bridge.offer(textOffer())
        let first = try #require(wire.lastOfferSerial)
        await bridge.revoke(sendEmpty: true)
        let empty = try #require(wire.lastOfferSerial)
        await bridge.revoke(sendEmpty: false)
        await bridge.offer(textOffer())
        let last = try #require(wire.lastOfferSerial)
        #expect(first < empty && empty < last && last - empty == 2)
        #expect(wire.messages[1] == .offer(serial: empty, mimeTypes: [], files: []))
    }

    /// Served whenever it comes, with no input first.
    @Test func aReadIsServedAtOnce() async throws {
        let source = FakeLocalSource(bytes: [1, 2, 3])
        let (bridge, wire) = recordedBridge(source)
        await bridge.offer(textOffer())
        let serial = try #require(wire.lastOfferSerial)
        await bridge.receive(.request(id: 2, serial: serial, item: .mime("text/plain")), payload: [])
        await wire.wait { $0.dataCount == 2 }
        #expect(
            Array(wire.messages.dropFirst()) == [
                .data(id: 2, offset: 0, dataLength: 3, done: false),
                .data(id: 2, offset: 3, dataLength: 0, done: true),
            ])
        #expect(source.callCount == 1)
    }

    /// Files aren't shared: a file request is refused.
    @Test func aFileRequestIsAlwaysRefused() async throws {
        let source = FakeLocalSource(bytes: [1])
        let (bridge, wire) = recordedBridge(source)
        await bridge.offer(textOffer())
        let serial = try #require(wire.lastOfferSerial)
        await bridge.receive(
            .request(id: 2, serial: serial, item: .file(index: 0)), payload: [])
        await wire.wait { $0.contains(.abort(id: 2)) }
        #expect(wire.contains(.abort(id: 2)))
        #expect(wire.dataCount == 0)
        #expect(source.callCount == 0)
    }

    @Test func aStaleSerialIsRefused() async throws {
        let (bridge, wire) = recordedBridge(FakeLocalSource(bytes: [1]))
        await bridge.offer(textOffer())
        let serial = try #require(wire.lastOfferSerial)
        await bridge.receive(
            .request(id: 2, serial: serial &+ 5, item: .mime(text)), payload: [])
        await wire.wait { $0.contains(.abort(id: 2)) }
        #expect(wire.contains(.abort(id: 2)))
    }

    @Test func aMimeNotOfferedIsRefused() async throws {
        let (bridge, wire) = recordedBridge(FakeLocalSource(bytes: [1]))
        await bridge.offer(textOffer())
        let serial = try #require(wire.lastOfferSerial)
        await bridge.receive(
            .request(id: 2, serial: serial, item: .mime(ClipboardMimes.png)), payload: [])
        await wire.wait { $0.contains(.abort(id: 2)) }
        #expect(wire.contains(.abort(id: 2)))
    }

    @Test func aReplacedClipboardIsRefused() async throws {
        let (bridge, wire) = recordedBridge(FakeLocalSource(error: .replaced))
        await bridge.offer(textOffer())
        let serial = try #require(wire.lastOfferSerial)
        await bridge.receive(.request(id: 2, serial: serial, item: .mime(text)), payload: [])
        await wire.wait { $0.contains(.abort(id: 2)) }
        #expect(wire.contains(.abort(id: 2)))
    }

    @Test func aNewOfferAbortsWhatTheOldOneServes() async throws {
        let (bridge, wire) = recordedBridge(FakeLocalSource(bytes: pattern(10 * 262_144)))
        await bridge.offer(textOffer())
        let serial = try #require(wire.lastOfferSerial)
        await bridge.receive(.request(id: 2, serial: serial, item: .mime(text)), payload: [])
        await wire.wait { $0.dataCount == 4 }
        await bridge.offer(textOffer(token: 2))
        #expect(wire.contains(.abort(id: 2)))
        await bridge.receive(.request(id: 4, serial: serial, item: .mime(text)), payload: [])
        await wire.wait { $0.contains(.abort(id: 4)) }
        #expect(wire.contains(.abort(id: 4)))
        #expect(wire.dataCount == 4)
    }

    @Test func aRevokeWithoutEmptySendsNothing() async {
        let (bridge, wire) = recordedBridge()
        await bridge.offer(textOffer())
        await bridge.revoke(sendEmpty: false)
        #expect(wire.messages.count == 1)
    }

    /// A read still running when the clock reaches the delay is reported, then how it ended.
    @Test func activityIsReportedForALongRead() async throws {
        let clock = ManualClock()
        let source = FakeLocalSource(bytes: [1, 2, 3], stalls: true)
        defer { source.stall?.release() }
        let (bridge, wire) = recordedBridge(source, clock: clock)
        await bridge.offer(textOffer())
        let serial = try #require(wire.lastOfferSerial)
        var events = bridge.events.makeAsyncIterator()
        await bridge.receive(.request(id: 2, serial: serial, item: .mime(text)), payload: [])
        try #require(await clock.waitForSleepers(1))
        clock.advance(by: .milliseconds(100))
        let running = try #require(await nextActivity(&events))
        #expect(running == ClipboardActivity(run: running.run, label: "text", done: 0, state: .running))
        source.stall?.release()
        let end = try #require(await nextActivity(&events))
        #expect(end == ClipboardActivity(run: running.run, label: "text", done: 3, state: .done))
    }

    /// The app's bridge reports a long read on the real clock, never before a second has passed.
    @Test func theAppsBridgeReportsALongReadAfterASecond() async throws {
        let (engine, wire) = recordedClient()
        let source = FakeLocalSource(bytes: [1, 2, 3], stalls: true)
        defer { source.stall?.release() }
        let bridge = ClipboardBridge(transfers: engine, source: source)
        await bridge.offer(textOffer())
        let serial = try #require(wire.lastOfferSerial)
        var events = bridge.events.makeAsyncIterator()
        let start = ContinuousClock.now
        await bridge.receive(.request(id: 2, serial: serial, item: .mime(text)), payload: [])
        #expect(await nextActivity(&events)?.state == .running)
        #expect(ContinuousClock.now - start >= .seconds(1))
        await bridge.close()
    }

    /// Two reads of one offer that end alike are two activities: the view shows the second.
    @Test func eachReadIsItsOwnActivity() async throws {
        let clock = ManualClock()
        let source = FakeLocalSource(bytes: [1, 2, 3], stalls: true)
        defer { source.stall?.release() }
        let (bridge, wire) = recordedBridge(source, clock: clock)
        await bridge.offer(textOffer())
        let serial = try #require(wire.lastOfferSerial)
        var events = bridge.events.makeAsyncIterator()
        var ends: [ClipboardActivity] = []
        for id: UInt32 in [2, 4] {
            source.stall?.rearm()
            await bridge.receive(.request(id: id, serial: serial, item: .mime(text)), payload: [])
            try #require(await clock.waitForSleepers(1))
            clock.advance(by: .milliseconds(100))
            try #require(await nextActivity(&events)?.state == .running)
            source.stall?.release()
            ends.append(try #require(await nextActivity(&events)))
        }
        #expect(ends.map(\.state) == [.done, .done])
        #expect(ends.first?.run != ends.last?.run)
    }

    /// A read that ends before the clock reaches the delay is never reported: its end stops the
    /// timer.
    @Test func aQuickReadIsNeverReported() async throws {
        let clock = ManualClock()
        let source = FakeLocalSource(bytes: [1, 2, 3], stalls: true)
        defer { source.stall?.release() }
        let (bridge, wire) = recordedBridge(source, clock: clock)
        await bridge.offer(textOffer())
        let serial = try #require(wire.lastOfferSerial)
        await bridge.receive(.request(id: 2, serial: serial, item: .mime(text)), payload: [])
        try #require(await clock.waitForSleepers(1))
        source.stall?.release()
        await wire.wait { $0.dataCount == 2 }
        try #require(wire.dataCount == 2, "the read didn't finish")
        try #require(await clock.waitForSleepers(0), "the read's end didn't stop its activity timer")
        await bridge.close()
        var events: [ClipboardBridgeEvent] = []
        for await event in bridge.events { events.append(event) }
        #expect(events.isEmpty)
    }

    @Test func aStuckSourceIsRefused() async throws {
        let source = FakeLocalSource(bytes: [1], stalls: true)
        defer { source.stall?.release() }
        let (bridge, wire) = recordedBridge(source, idleTimeout: .milliseconds(100))
        await bridge.offer(textOffer())
        let serial = try #require(wire.lastOfferSerial)
        await bridge.receive(.request(id: 2, serial: serial, item: .mime(text)), payload: [])
        await wire.wait { $0.contains(.abort(id: 2)) }
        #expect(wire.contains(.abort(id: 2)))
    }

    @Test func cancelStopsAReadStillBeingPrepared() async throws {
        let source = FakeLocalSource(bytes: [1], stalls: true)
        defer { source.stall?.release() }
        let (bridge, wire) = recordedBridge(source)
        await bridge.offer(textOffer())
        let serial = try #require(wire.lastOfferSerial)
        await bridge.receive(.request(id: 2, serial: serial, item: .mime(text)), payload: [])
        while source.callCount == 0 { try await Task.sleep(for: .milliseconds(10)) }
        await bridge.cancelServing()
        source.stall?.release()
        await wire.wait { $0.contains(.abort(id: 2)) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(wire.contains(.abort(id: 2)))
        #expect(wire.dataCount == 0)
    }

    @Test func aClosedBridgeIgnoresOffersAndRequests() async throws {
        let source = FakeLocalSource(bytes: [1])
        let (bridge, wire) = recordedBridge(source)
        await bridge.offer(textOffer())
        let serial = try #require(wire.lastOfferSerial)
        await bridge.close()
        await bridge.offer(textOffer(token: 2))
        await bridge.receive(
            .request(id: 2, serial: serial &+ 1, item: .mime(text)), payload: [])
        try await Task.sleep(for: .milliseconds(50))
        #expect(source.callCount == 0)
        #expect(wire.messages.count == 1)
    }

    @Test func labelsSayWhatIsMoving() {
        #expect(ClipboardActivity.label(mime: ClipboardMimes.png) == "image")
        #expect(ClipboardActivity.label(mime: ClipboardMimes.html) == "HTML")
        #expect(ClipboardActivity.label(mime: "UTF8_STRING") == "text")
    }
}

/// The next activity the bridge reports, skipping its other events; nil once it closes.
private func nextActivity(
    _ events: inout AsyncStream<ClipboardBridgeEvent>.Iterator
) async -> ClipboardActivity? {
    while let event = await events.next(isolation: #isolation) {
        if case .activity(let activity) = event { return activity }
    }
    return nil
}
