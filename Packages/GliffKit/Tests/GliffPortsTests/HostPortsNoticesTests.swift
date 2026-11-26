import GliffTestSupport
import GliffTransport
import Testing

@testable import GliffPorts

/// Which notices stay: a forwarded port's offer goes, a dismissed offer takes only its own
/// port, and a forward's notices are its own.
@Suite struct HostPortsNoticesTests {
    let bench = PortsBench()

    @Test func aForwardThatFailsLosesItsNotice() async throws {
        let (tab, hold, channel) = try await bench.firstFrame([(5173, "node")])
        await bench.registry.setAutomatic(true)
        channel.send([(5173, "node"), (3000, "node")])
        #expect(await bench.until { $0.notices.count == 1 && $0.forwarded.first?.state != .waiting })
        for port in 3000..<3100 { bench.mac.take(port) }
        bench.mac.take(50001)
        bench.opener.made[0].lose()
        #expect(await bench.until { $0.forwarded.first?.state == .waiting })
        let next = try await bench.connections.lease(for: bench.omarchy())
        #expect(await bench.until { $0.forwarded.first?.state == .failed(.localPortInUse) })
        #expect(try await bench.snapshot().notices.isEmpty)
        await hold.end()
        await next.end()
        await tab.end()
    }

    @Test func forwardingAnOfferedPortEndsItsNotice() async throws {
        let (tab, hold, channel) = try await bench.firstFrame([(5173, "node")])
        channel.send([(5173, "node"), (3000, "node")])
        #expect(await bench.until { $0.notices.count == 1 })
        try await bench.ports().forward(remote: 3000, destination: .localhost, localPort: nil)
        #expect(try await bench.snapshot().notices.isEmpty)
        await hold.end()
        await tab.end()
    }

    @Test func aStoppedForwardDoesNotOfferItsPortAgain() async throws {
        let (tab, hold, channel) = try await bench.firstFrame([(5173, "node")])
        channel.send([(5173, "node"), (3000, "node")])
        #expect(await bench.until { $0.notices.count == 1 })
        let id = try #require(
            await bench.ports().forward(remote: 3000, destination: .localhost, localPort: nil))
        try await bench.ports().stop(id)
        #expect(try await bench.snapshot().notices.isEmpty)
        await hold.end()
        await tab.end()
    }

    @Test func dismissingAnOfferKeepsANewerOne() async throws {
        let (tab, hold, channel) = try await bench.firstFrame([(5173, "node")])
        channel.send([(5173, "node"), (3000, "node")])
        #expect(await bench.until { $0.notices == [.listening(port: 3000, name: "node")] })
        channel.send([(5173, "node"), (3000, "node"), (4000, "python3")])
        #expect(await bench.until { $0.notices == [.several(ports: [3000, 4000])] })
        try await bench.ports().dismiss(.listening(port: 3000, name: "node"))
        #expect(try await bench.snapshot().notices == [.listening(port: 4000, name: "python3")])
        await hold.end()
        await tab.end()
    }

    @Test func dismissingSeveralKeepsALaterOffer() async throws {
        let (tab, hold, channel) = try await bench.firstFrame([(5173, "node")])
        channel.send([(5173, "node"), (3000, "node"), (4000, "node")])
        #expect(await bench.until { $0.notices == [.several(ports: [3000, 4000])] })
        channel.send([(5173, "node"), (3000, "node"), (4000, "node"), (8000, "python3")])
        #expect(await bench.until { $0.notices == [.several(ports: [3000, 4000, 8000])] })
        try await bench.ports().dismiss(.several(ports: [3000, 4000]))
        #expect(try await bench.snapshot().notices == [.listening(port: 8000, name: "python3")])
        await hold.end()
        await tab.end()
    }

    @Test func aSavedForwardEndsItsPortsOffer() async throws {
        let (tab, hold, channel) = try await bench.firstFrame([(5173, "node")])
        channel.send([(5173, "node"), (3000, "node")])
        #expect(await bench.until { $0.notices.count == 1 })
        let second = await bench.registry.hold(
            try bench.omarchy(), saved: [HostPortsForwardsTests.forward(3000)])
        #expect(try await bench.snapshot().notices.isEmpty)
        await second.end()
        await hold.end()
        await tab.end()
    }

    /// A saved 5173 whose Mac port is taken at each of `moves` reconnects; its id.
    func moving(_ moves: Int) async throws -> (tab: HostLease, hold: PortsHold, id: ForwardID) {
        let tab = try await bench.connections.lease(for: bench.omarchy())
        let hold = await bench.registry.hold(
            try bench.omarchy(), saved: [HostPortsForwardsTests.forward(5173)])
        #expect(await bench.until { $0.forwarded.first?.state == .active(local: 5173, loopbacks: .both) })
        let id = try #require(try await bench.row(5173)?.id)
        for move in 0..<moves {
            bench.opener.made[move].lose()
            #expect(await bench.until { $0.forwarded.first?.state == .waiting })
            bench.mac.take(5173 + move)
            _ = try await bench.connections.lease(for: bench.omarchy(), fresh: true)
            #expect(
                await bench.until {
                    $0.forwarded.first?.state == .active(local: 5174 + move, loopbacks: .both)
                })
        }
        return (tab, hold, id)
    }

    @Test func aSecondMoveReplacesTheFirstNotice() async throws {
        let (tab, hold, id) = try await moving(2)
        #expect(try await bench.snapshot().notices == [.moved(id: id, remote: 5173, from: 5174, to: 5175)])
        await hold.end()
        await tab.end()
    }

    @Test func stoppingAForwardKeepsAnotherOnesNotice() async throws {
        let (tab, hold, id) = try await moving(1)
        let elsewhere = ForwardDestination.address(PortListParserTests.ip("10.0.0.2"))
        let other = try #require(
            await bench.ports().forward(remote: 5173, destination: elsewhere, localPort: nil))
        try await bench.ports().stop(other)
        #expect(try await bench.snapshot().notices == [.moved(id: id, remote: 5173, from: 5173, to: 5174)])
        await hold.end()
        await tab.end()
    }
}
