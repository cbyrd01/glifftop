import GliffProtocol
import Testing

@testable import GliffClipboard

@Suite struct ClipboardTransfersTests {
    private let text = ClipboardItem.mime("text/plain")

    // MARK: Fetching

    @Test func aLargeItemRoundTrips() async throws {
        let bytes = pattern(3 * 262_144 + 17)
        let peers = BackToBack(items: [(text, bytes)])
        let sink = MemorySink(cap: ClipboardLimits.maxItem)
        let progress = TransferProgress()
        let got = try await peers.client.fetch(text, serial: 1, into: sink, cap: nil, progress: progress)
        #expect(got == UInt64(bytes.count))
        #expect(sink.bytes == bytes)
        #expect(progress.done == UInt64(bytes.count))
    }

    @Test func anEmptyItemRoundTrips() async throws {
        let peers = BackToBack(items: [(text, [])])
        let sink = MemorySink(cap: 10)
        #expect(try await peers.client.fetch(text, serial: 1, into: sink, cap: 10, progress: nil) == 0)
        #expect(sink.bytes.isEmpty)
    }

    @Test func aRefusedRequestIsAborted() async {
        let peers = BackToBack(items: [])
        await #expect(throws: TransferError.aborted) {
            try await peers.client.fetch(text, serial: 1, into: MemorySink(cap: 10), cap: 10, progress: nil)
        }
    }

    @Test func idsAreOdd() async throws {
        let (engine, wire) = recordedClient()
        for id: UInt32 in [1, 3, 5] {
            async let fetched = engine.fetch(text, serial: 7, into: MemorySink(cap: 1), cap: 1, progress: nil)
            await wire.wait { $0.contains(.request(id: id, serial: 7, item: .mime("text/plain"))) }
            _ = await engine.receive(.data(id: id, offset: 0, dataLength: 0, done: true), payload: [])
            #expect(try await fetched == 0)
        }
    }

    @Test func acksFollowEachChunkButTheLast() async throws {
        let (engine, wire) = recordedClient()
        async let fetched = engine.fetch(text, serial: 1, into: MemorySink(cap: 10), cap: 10, progress: nil)
        await wire.wait { !$0.messages.isEmpty }
        _ = await engine.receive(.data(id: 1, offset: 0, dataLength: 3, done: false), payload: [1, 2, 3])
        _ = await engine.receive(.data(id: 1, offset: 3, dataLength: 2, done: false), payload: [4, 5])
        _ = await engine.receive(.data(id: 1, offset: 5, dataLength: 0, done: true), payload: [])
        #expect(try await fetched == 5)
        #expect(
            wire.messages == [
                .request(id: 1, serial: 1, item: text), .ack(id: 1, received: 3), .ack(id: 1, received: 5),
            ])
    }

    @Test func aChunkOverTheLimitAbortsTheFetch() async {
        await expectFetchFails(
            .invalid, sending: .data(id: 1, offset: 0, dataLength: 262_145, done: false),
            payload: pattern(262_145), abortSent: true)
    }

    @Test func aPayloadOfTheWrongLength() async {
        await expectFetchFails(
            .invalid, sending: .data(id: 1, offset: 0, dataLength: 5, done: false),
            payload: [1, 2, 3, 4], abortSent: true)
    }

    @Test func aChunkOutOfOrder() async {
        await expectFetchFails(
            .invalid, sending: .data(id: 1, offset: 4, dataLength: 1, done: false),
            payload: [1], abortSent: true)
    }

    @Test func overTheCapAborts() async {
        await expectFetchFails(
            .tooLarge, sending: .data(id: 1, offset: 0, dataLength: 11, done: false),
            payload: pattern(11), abortSent: true)
    }

    @Test func aPeerAbortEndsTheFetch() async {
        await expectFetchFails(.aborted, sending: .abort(id: 1), payload: [], abortSent: false)
    }

    @Test func dataForAnUnknownIdIsIgnored() async {
        let (engine, wire) = recordedClient()
        let event = await engine.receive(.data(id: 99, offset: 0, dataLength: 1, done: true), payload: [1])
        #expect(event == nil)
        #expect(wire.messages.isEmpty)
    }

    @Test func cancellingAFetchSendsAbort() async {
        let (engine, wire) = recordedClient()
        let fetch = Task {
            try await engine.fetch(text, serial: 1, into: MemorySink(cap: 10), cap: 10, progress: nil)
        }
        await wire.wait { !$0.messages.isEmpty }
        fetch.cancel()
        await #expect(throws: TransferError.cancelled) { try await fetch.value }
        #expect(wire.contains(.abort(id: 1)))
    }

    @Test func aStalledFetchTimesOut() async {
        let (engine, wire) = recordedClient(idleTimeout: .milliseconds(100))
        await #expect(throws: TransferError.timedOut) {
            try await engine.fetch(text, serial: 1, into: MemorySink(cap: 10), cap: 10, progress: nil)
        }
        #expect(wire.contains(.abort(id: 1)))
    }

    @Test func closeEndsEveryFetch() async {
        let (engine, wire) = recordedClient()
        let one = Task {
            try await engine.fetch(text, serial: 1, into: MemorySink(cap: 10), cap: 10, progress: nil)
        }
        let two = Task {
            try await engine.fetch(text, serial: 1, into: MemorySink(cap: 10), cap: 10, progress: nil)
        }
        await wire.wait { $0.messages.count == 2 }
        await engine.close()
        await #expect(throws: TransferError.connectionEnded) { try await one.value }
        await #expect(throws: TransferError.connectionEnded) { try await two.value }
        await #expect(throws: TransferError.connectionEnded) {
            try await engine.fetch(text, serial: 1, into: MemorySink(cap: 10), cap: 10, progress: nil)
        }
        #expect(wire.messages.count == 2)
    }

    @Test func cancellingWithChunksQueuedStillCancels() async {
        let (engine, wire) = recordedClient()
        let sink = StallingSink()
        let fetch = Task { try await engine.fetch(text, serial: 1, into: sink, cap: nil, progress: nil) }
        await wire.wait { !$0.messages.isEmpty }
        for n in 0..<3 {
            _ = await engine.receive(
                .data(id: 1, offset: UInt64(n), dataLength: 1, done: n == 2), payload: [UInt8(n)])
        }
        while sink.stall.callCount == 0 { try? await Task.sleep(for: .milliseconds(10)) }
        fetch.cancel()
        sink.stall.release()
        await #expect(throws: TransferError.cancelled) { try await fetch.value }
        #expect(wire.contains(.abort(id: 1)))
        #expect(!wire.contains(.ack(id: 1, received: 2)))
    }

    @Test func aStalledSinkTimesOut() async {
        let (engine, wire) = recordedClient(idleTimeout: .milliseconds(100))
        let sink = StallingSink()
        defer { sink.stall.release() }
        let fetch = Task { try await engine.fetch(text, serial: 1, into: sink, cap: nil, progress: nil) }
        await wire.wait { !$0.messages.isEmpty }
        _ = await engine.receive(.data(id: 1, offset: 0, dataLength: 1, done: false), payload: [1])
        await #expect(throws: TransferError.timedOut) { try await fetch.value }
        #expect(wire.contains(.abort(id: 1)))
    }

    @Test func cancellingAStalledSinkCancels() async {
        let (engine, wire) = recordedClient()
        let sink = StallingSink()
        defer { sink.stall.release() }
        let fetch = Task { try await engine.fetch(text, serial: 1, into: sink, cap: nil, progress: nil) }
        await wire.wait { !$0.messages.isEmpty }
        _ = await engine.receive(.data(id: 1, offset: 0, dataLength: 1, done: false), payload: [1])
        while sink.stall.callCount == 0 { try? await Task.sleep(for: .milliseconds(10)) }
        fetch.cancel()
        await #expect(throws: TransferError.cancelled) { try await fetch.value }
        #expect(wire.contains(.abort(id: 1)))
    }

    // MARK: Serving

    @Test func aRequestWithAnOddIdIsRefused() async {
        let (engine, wire) = recordedClient()
        let event = await engine.receive(.request(id: 3, serial: 1, item: text), payload: [])
        #expect(event == nil)
        #expect(wire.messages == [.abort(id: 3)])
    }

    @Test func aRequestIsReported() async {
        let (engine, _) = recordedClient()
        let event = await engine.receive(.request(id: 4, serial: 9, item: .file(index: 2)), payload: [])
        #expect(event == .request(id: 4, serial: 9, item: .file(index: 2)))
    }

    @Test func anOfferIsReported() async {
        let (engine, _) = recordedClient()
        let event = await engine.receive(.offer(serial: 2, mimeTypes: ["a"], files: []), payload: [])
        #expect(event == .offer(serial: 2, mimeTypes: ["a"], files: []))
    }

    @Test func anEmptySourceSendsOneEmptyDoneChunk() async {
        let (engine, wire) = recordedClient()
        await engine.serve(id: 2, from: MemorySource([]), progress: nil)
        await wire.wait { !$0.messages.isEmpty }
        #expect(wire.messages == [.data(id: 2, offset: 0, dataLength: 0, done: true)])
    }

    @Test func neverMoreThanFourInFlight() async throws {
        let (engine, wire) = recordedClient()
        let progress = TransferProgress()
        await engine.serve(id: 2, from: MemorySource(pattern(7 * 262_144)), progress: progress)
        await wire.wait { $0.dataCount == 4 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(wire.dataCount == 4)
        #expect(progress.done == 4 * 262_144)
        _ = await engine.receive(.ack(id: 2, received: 262_144), payload: [])
        await wire.wait { $0.dataCount == 5 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(wire.dataCount == 5)
        #expect(wire.messages[4] == .data(id: 2, offset: 4 * 262_144, dataLength: 262_144, done: false))
    }

    @Test func aServeKeepsGoingThroughManyAcks() async throws {
        let (engine, wire) = recordedClient()
        await engine.serve(id: 2, from: MemorySource(pattern(40 * 262_144)), progress: nil)
        for n in 1...36 {
            await wire.wait { $0.dataCount == n + 3 }
            _ = await engine.receive(.ack(id: 2, received: UInt64(n) * 262_144), payload: [])
        }
        await wire.wait { $0.dataCount == 40 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(wire.dataCount == 40)
        #expect(!wire.contains(.abort(id: 2)))
    }

    @Test func aStalledSourceIsAborted() async {
        let (engine, wire) = recordedClient(idleTimeout: .milliseconds(100))
        let source = StallingSource()
        defer { source.stall.release() }
        await engine.serve(id: 2, from: source, progress: nil)
        await wire.wait { $0.contains(.abort(id: 2)) }
        #expect(wire.messages == [.abort(id: 2)])
    }

    @Test func anOversizedReadIsSplit() async {
        let (engine, wire) = recordedClient()
        await engine.serve(id: 2, from: GreedySource(pattern(600_000)), progress: nil)
        await wire.wait { $0.dataCount == 4 }
        #expect(
            wire.messages == [
                .data(id: 2, offset: 0, dataLength: 262_144, done: false),
                .data(id: 2, offset: 262_144, dataLength: 262_144, done: false),
                .data(id: 2, offset: 524_288, dataLength: 75_712, done: false),
                .data(id: 2, offset: 600_000, dataLength: 0, done: true),
            ])
    }

    @Test func aBadAckAbortsTheServe() async {
        let (engine, wire) = recordedClient()
        await engine.serve(id: 2, from: MemorySource(pattern(10 * 262_144)), progress: nil)
        await wire.wait { $0.dataCount == 4 }
        _ = await engine.receive(.ack(id: 2, received: 5 * 262_144), payload: [])
        await wire.wait { $0.contains(.abort(id: 2)) }
        #expect(wire.contains(.abort(id: 2)))
    }

    @Test func aSourceErrorSendsAbort() async throws {
        let (engine, wire) = recordedClient()
        await engine.serve(id: 2, from: FailingSource(), progress: nil)
        await wire.wait { $0.contains(.abort(id: 2)) }
        #expect(wire.contains(.abort(id: 2)))
    }

    @Test func aPeerAbortStopsTheServe() async throws {
        let (engine, wire) = recordedClient()
        await engine.serve(id: 2, from: MemorySource(pattern(10 * 262_144)), progress: nil)
        await wire.wait { $0.dataCount == 4 }
        _ = await engine.receive(.abort(id: 2), payload: [])
        _ = await engine.receive(.ack(id: 2, received: 4 * 262_144), payload: [])
        try await Task.sleep(for: .milliseconds(100))
        #expect(wire.dataCount == 4)
        #expect(!wire.contains(.abort(id: 2)))
    }

    @Test func abortServingStopsEveryServe() async throws {
        let (engine, wire) = recordedClient()
        await engine.serve(id: 2, from: MemorySource(pattern(10 * 262_144)), progress: nil)
        await engine.serve(id: 4, from: MemorySource(pattern(10 * 262_144)), progress: nil)
        await wire.wait { $0.dataCount == 8 }
        await engine.abortServing()
        _ = await engine.receive(.ack(id: 2, received: 4 * 262_144), payload: [])
        try await Task.sleep(for: .milliseconds(100))
        #expect(wire.dataCount == 8)
        #expect(wire.contains(.abort(id: 2)))
        #expect(wire.contains(.abort(id: 4)))
    }

    @Test func aRepeatedIdEndsTheFirstServe() async throws {
        let (engine, wire) = recordedClient()
        await engine.serve(id: 2, from: MemorySource(pattern(10 * 262_144)), progress: nil)
        await wire.wait { $0.dataCount == 4 }
        await engine.serve(id: 2, from: MemorySource([9]), progress: nil)
        await wire.wait { $0.dataCount == 6 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(
            Array(wire.messages.suffix(2)) == [
                .data(id: 2, offset: 0, dataLength: 1, done: false),
                .data(id: 2, offset: 1, dataLength: 0, done: true),
            ])
    }

    @Test func closeStopsServing() async throws {
        let (engine, wire) = recordedClient()
        await engine.serve(id: 2, from: MemorySource(pattern(10 * 262_144)), progress: nil)
        await wire.wait { $0.dataCount == 4 }
        await engine.close()
        _ = await engine.receive(.ack(id: 2, received: 4 * 262_144), payload: [])
        await engine.serve(id: 4, from: MemorySource([1]), progress: nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(wire.messages.count == 4)
    }

    @Test func aServeSaysHowItEnded() async {
        let (engine, wire) = recordedClient()
        let ends = Ends()
        await engine.serve(id: 2, from: MemorySource([1]), progress: nil, onEnd: ends.callback(2))
        await engine.serve(
            id: 4, from: MemorySource(pattern(10 * 262_144)), progress: nil, onEnd: ends.callback(4))
        await engine.serve(
            id: 6, from: MemorySource(pattern(10 * 262_144)), progress: nil, onEnd: ends.callback(6))
        await wire.wait { $0.dataCount == 10 }
        _ = await engine.receive(.abort(id: 4), payload: [])
        await engine.abortServing(.replaced)
        await ends.wait(for: 3)
        #expect(ends.all == [2: TransferError?.none, 4: .aborted, 6: .replaced])
    }

    @Test func anOfferIsSent() async {
        let (engine, wire) = recordedClient()
        await engine.sendOffer(serial: 3, mimeTypes: ["text/html"], files: [])
        #expect(wire.messages == [.offer(serial: 3, mimeTypes: ["text/html"], files: [])])
    }

    @Test func errorsSayWhatHappened() {
        #expect(TransferError.replaced.message == "The copy was replaced before it could be pasted.")
        #expect(TransferError.tooLarge.message == "It's too large to paste (over 32 MB).")
        #expect(TransferError.connectionEnded.message == "The connection ended.")
    }

    /// Starts a fetch (cap 10), answers its request with `message`, and expects `error`.
    private func expectFetchFails(
        _ error: TransferError, sending message: ClipboardMessage, payload: [UInt8], abortSent: Bool
    ) async {
        let (engine, wire) = recordedClient()
        let fetched = Task {
            try await engine.fetch(text, serial: 1, into: MemorySink(cap: 10), cap: 10, progress: nil)
        }
        await wire.wait { !$0.messages.isEmpty }
        _ = await engine.receive(message, payload: payload)
        await #expect(throws: error) { try await fetched.value }
        #expect(wire.contains(.abort(id: 1)) == abortSent)
    }
}
