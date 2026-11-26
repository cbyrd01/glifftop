import Testing

@testable import GliffInput

/// What the remote has seen pressed: a press goes out once, a release only for what is held,
/// and everything held can be let go at once.
@Suite struct InputLedgerTests {
    @Test func pressOnce() {
        var ledger = InputLedger()
        let first = ledger.press(key: 30)
        #expect(first == [.key(code: 30, pressed: true)])
        #expect(ledger.heldKeys == [30])
    }

    /// A fresh press of a key already held means its key-up never arrived: let go of it on
    /// the remote first, so it can't stay down there.
    @Test func pressingAHeldKeyAgainReleasesItFirst() {
        var ledger = InputLedger()
        _ = ledger.press(key: 30)
        let again = ledger.press(key: 30)
        #expect(again == [.key(code: 30, pressed: false), .key(code: 30, pressed: true)])
        #expect(ledger.heldKeys == [30])
    }

    @Test func releaseOnlyWhatIsHeld() {
        var ledger = InputLedger()
        let unheld = ledger.release(key: 30)
        #expect(unheld == nil)
        _ = ledger.press(key: 30)
        let held = ledger.release(key: 30)
        #expect(held == .key(code: 30, pressed: false))
        #expect(ledger.heldKeys.isEmpty)
    }

    @Test func releaseAllInReverseOrder() {
        var ledger = InputLedger()
        _ = ledger.press(key: 125)
        _ = ledger.press(key: 17)
        let released = ledger.releaseAll()
        #expect(released == [.key(code: 17, pressed: false), .key(code: 125, pressed: false)])
        #expect(ledger.heldKeys.isEmpty)
        let again = ledger.releaseAll()
        #expect(again.isEmpty)
    }

    /// A ⌘ chord going to the Mac lets go of the keys only: a drag's button stays down.
    @Test func releaseAllKeysKeepsButtons() {
        var ledger = InputLedger()
        _ = ledger.press(button: 0x110)
        _ = ledger.press(key: 125)
        _ = ledger.press(key: 30)
        #expect(ledger.releaseAllKeys() == [.key(code: 30, pressed: false), .key(code: 125, pressed: false)])
        #expect(ledger.heldKeys.isEmpty)
        #expect(ledger.heldButtons == [0x110])
    }

    @Test func aReleasedKeyCanBePressedAgain() {
        var ledger = InputLedger()
        _ = ledger.press(key: 30)
        _ = ledger.release(key: 30)
        let again = ledger.press(key: 30)
        #expect(again == [.key(code: 30, pressed: true)])
        #expect(ledger.heldKeys == [30])
    }

    @Test func buttonsFollowTheKeysRules() {
        var ledger = InputLedger()
        let first = ledger.press(button: 0x110)
        #expect(first == [.pointerButton(code: 0x110, pressed: true)])
        let again = ledger.press(button: 0x110)
        #expect(
            again == [
                .pointerButton(code: 0x110, pressed: false), .pointerButton(code: 0x110, pressed: true),
            ])
        #expect(ledger.heldButtons == [0x110])
        #expect(ledger.release(button: 0x111) == nil)
        #expect(ledger.release(button: 0x110) == .pointerButton(code: 0x110, pressed: false))
        #expect(ledger.heldButtons.isEmpty)
    }

    /// Buttons first, then keys, each last pressed first.
    @Test func releaseAllLetsGoOfButtonsThenKeys() {
        var ledger = InputLedger()
        _ = ledger.press(key: 29)
        _ = ledger.press(button: 0x110)
        let released = ledger.releaseAll()
        #expect(released == [.pointerButton(code: 0x110, pressed: false), .key(code: 29, pressed: false)])
        #expect(ledger.heldButtons.isEmpty && ledger.heldKeys.isEmpty)
    }

    /// The confined pointer ending mid-drag lets go of the buttons only.
    @Test func releaseAllButtonsKeepsKeys() {
        var ledger = InputLedger()
        _ = ledger.press(key: 125)
        _ = ledger.press(button: 0x110)
        _ = ledger.press(button: 0x111)
        #expect(
            ledger.releaseAllButtons() == [
                .pointerButton(code: 0x111, pressed: false), .pointerButton(code: 0x110, pressed: false),
            ])
        #expect(ledger.heldButtons.isEmpty)
        #expect(ledger.heldKeys == [125])
    }
}
