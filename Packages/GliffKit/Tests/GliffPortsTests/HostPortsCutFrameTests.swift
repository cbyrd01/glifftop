import GliffTestSupport
import GliffTransport
import Testing

@testable import GliffPorts

/// A frame cut at its 64 sockets says nothing of the ports past the cut: none of them is
/// gone, and none is new when it comes back.
@Suite struct HostPortsCutFrameTests {
    let bench = PortsBench()

    /// Sixty-five unnamed ports from 1001, past the reader's 64.
    let crowded: [(Int, String?)] = (1001...1065).map { ($0, nil) }

    @Test func aCutFrameStartsNoAbsence() async throws {
        let (tab, hold, channel) = try await bench.firstFrame([(5173, "node")])
        await bench.registry.setAutomatic(true)
        channel.send([(5173, "node"), (3000, "node")])
        #expect(await bench.until { $0.forwarded.first?.state == .active(local: 3000, loopbacks: .both) })
        channel.send(crowded)
        #expect(await bench.until { $0.available.contains { $0.port == 1001 } })
        #expect(try await bench.ports().absent.isEmpty)
        await hold.end()
        await tab.end()
    }

    @Test func aCutFrameEndsAnAbsenceUnderWay() async throws {
        let (tab, hold, channel) = try await bench.firstFrame([(5173, "node")])
        await bench.registry.setAutomatic(true)
        channel.send([(5173, "node"), (3000, "node")])
        #expect(await bench.until { $0.forwarded.first?.state == .active(local: 3000, loopbacks: .both) })
        channel.send([(5173, "node")])
        #expect(await bench.clock.waitForSleepers(1))
        channel.send(crowded)
        #expect(await bench.until { $0.available.contains { $0.port == 1001 } })
        #expect(try await bench.ports().absent.isEmpty)
        await hold.end()
        await tab.end()
    }

    @Test func aPortPastTheCutIsNotNewAgain() async throws {
        let (tab, hold, channel) = try await bench.firstFrame([(3000, nil)])
        channel.send(crowded)
        #expect(await bench.until { $0.available.contains { $0.port == 1001 } })
        channel.send([(3000, nil)])
        #expect(await bench.until { $0.available.map(\.port) == [3000] })
        #expect(try await bench.snapshot().notices.isEmpty)
        await hold.end()
        await tab.end()
    }

    @Test func anOfferPastTheCutStays() async throws {
        let (tab, hold, channel) = try await bench.firstFrame([(5173, nil)])
        channel.send([(5173, nil), (3000, nil)])
        #expect(await bench.until { $0.notices == [.listening(port: 3000, name: nil)] })
        channel.send(crowded)
        #expect(await bench.until { $0.available.contains { $0.port == 1001 } })
        #expect(try await bench.ports().offered.map(\.port).contains(3000))
        await hold.end()
        await tab.end()
    }
}
