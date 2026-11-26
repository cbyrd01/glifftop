import GliffTransport
import Synchronization
import Testing

@testable import GliffPorts

/// Which Mac port a forward takes.
@Suite struct LocalPortChooserTests {
    /// A chooser whose check finds `taken` taken, `ipv4Only` free on 127.0.0.1 alone, and the
    /// rest free; `pick` gives `picked`. It records the ports checked.
    final class Fake: Sendable {
        let taken: Set<Int>
        let ipv4Only: Set<Int>
        let picked: Int?
        let checked = Mutex<[Int]>([])

        init(taken: Set<Int> = [], ipv4Only: Set<Int> = [], picked: Int? = 50001) {
            (self.taken, self.ipv4Only, self.picked) = (taken, ipv4Only, picked)
        }

        var chooser: LocalPortChooser {
            LocalPortChooser(
                check: { [self] port in
                    checked.withLock { $0.append(port) }
                    if taken.contains(port) { return .taken }
                    return ipv4Only.contains(port) ? .freeIPv4Only : .free
                },
                pick: { [picked] in picked })
        }
    }

    @Test func theRemoteNumberIsUsedWhenFree() {
        #expect(Fake().chooser.choose(remote: 5173) == .init(port: 5173, loopbacks: .both))
    }

    /// A remembered port out of range (a hand-edited file) is ignored, never a crash.
    @Test(arguments: [70000, 65600, 0, -1]) func aRememberedPortOutOfRangeIsIgnored(_ remembered: Int) {
        #expect(
            Fake().chooser.choose(remote: 5173, remembered: remembered) == .init(port: 5173, loopbacks: .both)
        )
    }

    /// Counting up never lands on a port it is told to skip (a database port, for an
    /// automatic forward).
    @Test func countingUpSkipsWhatItIsToldTo() {
        let fake = Fake(taken: [6378])
        #expect(fake.chooser.choose(remote: 6378, skipping: [6379]) == .init(port: 6380, loopbacks: .both))
        #expect(!fake.checked.withLock { $0 }.contains(6379))
    }

    @Test func aPickedPortToSkipIsNoChoice() {
        let fake = Fake(taken: Set(5173..<5273), picked: 6379)
        #expect(fake.chooser.choose(remote: 5173, skipping: [6379]) == nil)
    }

    @Test func aTakenPortCountsUp() {
        let fake = Fake(taken: [5173, 5174])
        #expect(fake.chooser.choose(remote: 5173) == .init(port: 5175, loopbacks: .both))
    }

    @Test func underTenTwentyFourStartsAt8000() {
        let fake = Fake(taken: [8000])
        #expect(fake.chooser.choose(remote: 80) == .init(port: 8001, loopbacks: .both))
        #expect(!fake.checked.withLock { $0 }.contains(80))
    }

    @Test func aRememberedPortComesFirst() {
        #expect(Fake().chooser.choose(remote: 5173, remembered: 5180) == .init(port: 5180, loopbacks: .both))
    }

    @Test func afterAHundredTriesItPicks() {
        let fake = Fake(taken: Set(5173...5272))
        #expect(fake.chooser.choose(remote: 5173) == .init(port: 50001, loopbacks: .both))
        #expect(fake.checked.withLock { $0 }.count == 101)
    }

    @Test func countingStopsAtTheLastPort() {
        let fake = Fake(taken: [65534, 65535])
        #expect(fake.chooser.choose(remote: 65534) == .init(port: 50001, loopbacks: .both))
        #expect(fake.checked.withLock { $0 } == [65534, 65535, 50001])
    }

    @Test func aTakenPickIsNothing() {
        let fake = Fake(taken: Set(5173...5272).union([50001]))
        #expect(fake.chooser.choose(remote: 5173) == nil)
        #expect(Fake(taken: Set(5173...5272), picked: nil).chooser.choose(remote: 5173) == nil)
    }

    @Test func anIPv4OnlyMacGivesIPv4Only() {
        let fake = Fake(ipv4Only: [5173])
        #expect(fake.chooser.choose(remote: 5173) == .init(port: 5173, loopbacks: .ipv4Only))
        #expect(fake.chooser.exactly(5173) == .init(port: 5173, loopbacks: .ipv4Only))
    }

    @Test func aTypedPortIsTriedAlone() {
        let fake = Fake(taken: [5173])
        #expect(fake.chooser.exactly(5173) == nil)
        #expect(fake.checked.withLock { $0 } == [5173])
        #expect(fake.chooser.exactly(5174) == .init(port: 5174, loopbacks: .both))
    }

    @Test func aForwardWithNothingRememberedStartsAtItsOwnPort() {
        #expect(LocalPortChooser.start(for: 5173) == 5173)
        #expect(LocalPortChooser.start(for: 1024) == 1024)
        #expect(LocalPortChooser.start(for: 80) == 8000)
    }

    @Test(arguments: [0, 80, 1023, 65536]) func aTypedPortOutsideTheRangeIsRefused(_ port: Int) {
        let fake = Fake()
        #expect(fake.chooser.exactly(port) == nil)
        #expect(fake.checked.withLock { $0 }.isEmpty)
    }
}
