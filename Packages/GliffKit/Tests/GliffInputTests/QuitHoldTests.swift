import Testing

@testable import GliffInput

/// The ⌘Q guard's timing: a first press shows the message, holding a second quits, letting go
/// early leaves the message 1.5 s, a fresh press while it shows quits.
@Suite struct QuitHoldTests {
    private static func ms(_ value: Int) -> Duration { .milliseconds(value) }

    /// A hold that showed at 0.
    private func shown() -> QuitHold {
        var hold = QuitHold()
        _ = hold.keyDown(isRepeat: false, at: .zero)
        return hold
    }

    @Test func theFirstPressShows() {
        var hold = QuitHold()
        #expect(hold.keyDown(isRepeat: false, at: .zero) == .show)
        #expect(hold.isShowing)
        #expect(hold.nextDeadline == .seconds(1))
    }

    @Test func holdingOneSecondQuits() {
        var hold = shown()
        #expect(hold.tick(at: Self.ms(999), keysDown: true) == .none)
        #expect(hold.tick(at: .seconds(1), keysDown: true) == .quit)
        #expect(!hold.isShowing)
    }

    /// The timer ran late: a let-go after the full second still quits.
    @Test func aLetGoAfterTheHoldQuits() {
        var hold = shown()
        #expect(hold.keyUp(at: Self.ms(1100)) == .quit)
        #expect(!hold.isShowing)
    }

    @Test func lettingGoEarlyCancelsAndLingers() {
        var hold = shown()
        #expect(hold.keyUp(at: Self.ms(900)) == .none)
        #expect(hold.isShowing)
        #expect(hold.tick(at: .seconds(1), keysDown: true) == .none)
        #expect(hold.tick(at: Self.ms(2390), keysDown: false) == .none)
        #expect(hold.tick(at: Self.ms(2400), keysDown: false) == .hide)
        #expect(!hold.isShowing)
    }

    @Test func aSecondPressWhileShowingQuits() {
        var hold = shown()
        _ = hold.keyUp(at: Self.ms(300))
        #expect(hold.keyDown(isRepeat: false, at: Self.ms(800)) == .quit)
    }

    @Test func repeatsChangeNothing() {
        var hold = shown()
        for time in [200, 500, 900] {
            #expect(hold.keyDown(isRepeat: true, at: Self.ms(time)) == .none)
        }
        #expect(hold.tick(at: .seconds(1), keysDown: true) == .quit)
    }

    @Test func aPressAfterTheLingerStartsOver() {
        var hold = shown()
        _ = hold.keyUp(at: Self.ms(100))
        #expect(hold.tick(at: Self.ms(1600), keysDown: false) == .hide)
        #expect(hold.keyDown(isRepeat: false, at: .seconds(2)) == .show)
    }

    /// The keys' real state, read when the hold is due, says they're up: no quit.
    @Test func theTimersCheckFailingCancels() {
        var hold = shown()
        #expect(hold.tick(at: .seconds(1), keysDown: false) == .none)
        #expect(hold.isShowing)
        #expect(hold.tick(at: Self.ms(2499), keysDown: false) == .none)
        #expect(hold.tick(at: Self.ms(2500), keysDown: false) == .hide)
    }

    @Test func theNextDeadlineFollowsTheState() {
        var hold = QuitHold()
        #expect(hold.nextDeadline == nil)
        _ = hold.keyDown(isRepeat: false, at: Self.ms(100))
        #expect(hold.nextDeadline == Self.ms(1100))
        _ = hold.keyUp(at: Self.ms(400))
        #expect(hold.nextDeadline == Self.ms(1900))
        _ = hold.tick(at: Self.ms(1900), keysDown: false)
        #expect(hold.nextDeadline == nil)
    }
}
