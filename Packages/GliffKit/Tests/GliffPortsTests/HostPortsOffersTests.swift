import GliffTestSupport
import GliffTransport
import Testing

@testable import GliffPorts

/// Offers: the first frame is silent, a new port makes a notice (several coalesce), Ignore
/// hides a port, and with the automatic setting new ports are forwarded and stop once gone.
@Suite struct HostPortsOffersTests {
    let bench = PortsBench()

    @Test func theFirstFrameIsSilent() async throws {
        let (tab, hold, _) = try await bench.firstFrame([(5173, "node"), (8080, "python3")])
        #expect(try await bench.snapshot().notices.isEmpty)
        await hold.end()
        await tab.end()
    }

    @Test func aNewPortMakesANotice() async throws {
        let (tab, hold, channel) = try await bench.firstFrame([(5173, "node")])
        channel.send([(5173, "node"), (3000, "node")])
        #expect(await bench.until { $0.notices == [.listening(port: 3000, name: "node")] })
        await hold.end()
        await tab.end()
    }

    @Test func severalAtOnceCoalesce() async throws {
        let (tab, hold, channel) = try await bench.firstFrame([(5173, "node")])
        channel.send([(5173, "node"), (3000, "node"), (4000, nil), (8000, "python3")])
        #expect(await bench.until { $0.notices == [.several(ports: [3000, 4000, 8000])] })
        await hold.end()
        await tab.end()
    }

    @Test func ignoreHidesThatPort() async throws {
        let (tab, hold, channel) = try await bench.firstFrame([(5173, "node")])
        channel.send([(5173, "node"), (3000, "node")])
        #expect(await bench.until { $0.notices.count == 1 })
        try await bench.ports().ignore(3000)
        #expect(try await bench.snapshot().notices.isEmpty)
        channel.send([(5173, "node")])
        #expect(await bench.until { $0.available.count == 1 })
        channel.send([(5173, "node"), (3000, "node")])
        #expect(await bench.until { $0.available.count == 2 })
        #expect(try await bench.snapshot().notices.isEmpty)
        await hold.end()
        await tab.end()
    }

    @Test func aNoticeGoesWithItsPort() async throws {
        let (tab, hold, channel) = try await bench.firstFrame([(5173, "node")])
        channel.send([(5173, "node"), (3000, "node")])
        #expect(await bench.until { $0.notices.count == 1 })
        channel.send([(5173, "node")])
        #expect(await bench.until { $0.notices.isEmpty })
        await hold.end()
        await tab.end()
    }

    @Test func aForwardRowSaysWhetherItsPortListens() async throws {
        let (tab, hold, channel) = try await bench.firstFrame([(5173, "node")])
        try await bench.ports().forward(remote: 5173, destination: .localhost, localPort: nil)
        try await bench.ports().forward(remote: 3000, destination: .localhost, localPort: nil)
        channel.send([(5173, "node")])
        #expect(await bench.until { $0.forwarded.map(\.listening) == [true, false] })
        #expect(try await bench.snapshot().available.isEmpty)
        await hold.end()
        await tab.end()
    }

    /// The automatic setting on, after a first frame of 5173.
    func automatic() async throws -> (tab: HostLease, hold: PortsHold, channel: PortsChannel) {
        let watching = try await bench.firstFrame([(5173, "node")])
        await bench.registry.setAutomatic(true)
        return watching
    }

    @Test func automaticForwardsANewPort() async throws {
        let (tab, hold, channel) = try await automatic()
        channel.send([(5173, "node"), (3000, "node")])
        #expect(await bench.until { $0.forwarded.first?.state == .active(local: 3000, loopbacks: .both) })
        let snapshot = try await bench.snapshot()
        #expect(snapshot.forwarded.map(\.kind) == [.automatic])
        let id = try #require(snapshot.forwarded.first?.id)
        #expect(snapshot.notices == [.forwarded(id: id, remote: 3000, local: 3000)])
        await hold.end()
        await tab.end()
    }

    @Test func aRestartWithinTenSecondsKeepsTheForward() async throws {
        let (tab, hold, channel) = try await automatic()
        channel.send([(5173, "node"), (3000, "node")])
        #expect(await bench.until { $0.forwarded.first?.state == .active(local: 3000, loopbacks: .both) })
        channel.send([(5173, "node")])
        #expect(await bench.clock.waitForSleepers(1))
        bench.clock.advance(by: .seconds(4))
        channel.send([(5173, "node"), (3000, "node")])
        #expect(await bench.until { $0.forwarded.first?.listening == true })
        #expect(try await bench.ports().absent.isEmpty)
        bench.clock.advance(by: .seconds(10))
        #expect(try await bench.row(3000)?.state == .active(local: 3000, loopbacks: .both))
        #expect(!bench.opener.made[0].calls.contains(.cancel(3000, .ipv4)))
        await hold.end()
        await tab.end()
    }

    @Test func twelveSecondsAbsentStopsIt() async throws {
        let (tab, hold, channel) = try await automatic()
        channel.send([(5173, "node"), (3000, "node")])
        #expect(await bench.until { $0.forwarded.first?.state == .active(local: 3000, loopbacks: .both) })
        channel.send([(5173, "node")])
        #expect(await bench.clock.waitForSleepers(1))
        bench.clock.advance(by: .seconds(12))
        #expect(await bench.until { $0.forwarded.isEmpty && $0.notices.isEmpty })
        #expect(bench.opener.made[0].calls.suffix(2) == [.cancel(3000, .ipv4), .cancel(3000, .ipv6)])
        await hold.end()
        await tab.end()
    }

    @Test func aManualForwardIsNeverStoppedForAbsence() async throws {
        let (tab, hold, channel) = try await automatic()
        try await bench.ports().forward(remote: 3000, destination: .localhost, localPort: nil)
        channel.send([(5173, "node"), (3000, "node")])
        channel.send([(5173, "node")])
        #expect(await bench.until { $0.forwarded.first?.listening == false })
        #expect(try await bench.ports().absent.isEmpty)
        bench.clock.advance(by: .seconds(12))
        #expect(try await bench.row(3000)?.state == .active(local: 3000, loopbacks: .both))
        await hold.end()
        await tab.end()
    }

    @Test func aDatabasePortIsOfferedNotForwarded() async throws {
        let (tab, hold, channel) = try await automatic()
        channel.send([(5173, "node"), (5432, "postgres")])
        #expect(await bench.until { $0.notices == [.listening(port: 5432, name: "postgres")] })
        #expect(try await bench.snapshot().forwarded.isEmpty)
        await hold.end()
        await tab.end()
    }

    @Test func withoutNamesNothingIsAutomatic() async throws {
        let (tab, hold, channel) = try await automatic()
        channel.send([(5173, nil), (3000, nil)])
        #expect(await bench.until { $0.notices == [.listening(port: 3000, name: nil)] })
        #expect(try await bench.snapshot().forwarded.isEmpty)
        await hold.end()
        await tab.end()
    }
}
