import GliffInput
import Testing

@testable import GliffSession

@Suite struct InputQueueTests {
    @Test func takesEverythingInOrder() {
        let queue = InputQueue()
        queue.append(.keymap("a"))
        queue.append(.keymap("b"))
        #expect(queue.takeAll() == [.keymap("a"), .keymap("b")])
        #expect(queue.takeAll().isEmpty)
    }

    /// Once the session has ended nothing is kept, and the wakeups end.
    @Test func closedKeepsNothing() async {
        let queue = InputQueue()
        queue.close()
        queue.append(.keymap("a"))
        #expect(queue.takeAll().isEmpty)
        for await _ in queue.wakeups { Issue.record("a wakeup after close") }
    }
}
