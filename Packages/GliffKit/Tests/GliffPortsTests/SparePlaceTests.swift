import Synchronization
import Testing

@testable import GliffPorts

/// The watcher's spare place: a tab that takes it waits for a channel still opening there,
/// which the host counts until it is closed.
@Suite struct SparePlaceTests {
    final class Flag: Sendable {
        private let state = Mutex(false)
        var isSet: Bool { state.withLock { $0 } }
        func set() { state.withLock { $0 = true } }
    }

    @Test func aYieldWaitsForAChannelStillOpening() async {
        let place = SparePlace()
        #expect(place.beginOpening())
        let returned = Flag()
        let yielding = Task {
            await place.yield()
            returned.set()
        }
        #expect(await eventually { place.yielded })
        for _ in 0..<100 { await Task.yield() }
        #expect(!returned.isSet)
        place.settle()
        await yielding.value
        #expect(returned.isSet)
    }

    @Test func anEarlierChannelDoesNotEndTheWait() async {
        let place = SparePlace()
        #expect(place.beginOpening())
        #expect(place.hold(PortsChannel(command: "earlier")))
        place.settle()
        #expect(place.beginOpening())
        let returned = Flag()
        let yielding = Task {
            await place.yield()
            returned.set()
        }
        #expect(await eventually { place.yielded })
        for _ in 0..<100 { await Task.yield() }
        #expect(!returned.isSet)
        place.settle()
        await yielding.value
    }

    @Test func noChannelOpensOnceThePlaceIsGone() async {
        let place = SparePlace()
        await place.yield()
        #expect(!place.beginOpening())
    }
}
