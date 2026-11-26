import GliffInput
import Testing

@testable import GliffSession

@Suite struct InputQueueTests {
    @Test func takesEverythingInOrder() {
        let queue = InputQueue()
        queue.append(.keymap("a"))
        queue.append(.keymap("b"))
        #expect(queue.takeAll().inputs == [.keymap("a"), .keymap("b")])
        #expect(queue.takeAll() == InputQueue.Taken())
    }

    /// Once the session has ended nothing is kept, and the wakeups end.
    @Test func closedKeepsNothing() async {
        let queue = InputQueue()
        queue.close()
        queue.append(.keymap("a"))
        #expect(queue.takeAll() == InputQueue.Taken())
        for await _ in queue.wakeups { Issue.record("a wakeup after close") }
    }

    /// A closing session's releases still go, and their fences with them, held or not.
    @Test func takeAllKeepsTheFences() {
        let queue = InputQueue()
        let release = InputBarrier.Release(sender: InputBarrier.Sender(), number: 1)
        queue.append(.until(.seconds(60), awaiting: nil))
        queue.append(.keymap("a"))
        queue.append(.fence(release))
        let taken = queue.takeAll()
        #expect(taken.inputs == [.keymap("a")])
        #expect(taken.fences == [release])
    }

    /// The fences of what a close drops: their releases never go.
    @Test func closeReturnsTheFencesItDrops() {
        let queue = InputQueue()
        let release = InputBarrier.Release(sender: InputBarrier.Sender(), number: 1)
        queue.append(.fence(release))
        #expect(queue.close() == [release])
        #expect(queue.close().isEmpty)
    }
}
