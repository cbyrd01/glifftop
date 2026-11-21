import Testing

@testable import GliffInput

/// Mac virtual key codes (kVK, what `NSEvent.keyCode` reports) to Linux evdev codes (what
/// Gliff's `Key` carries), by position.
@Suite struct MacKeyCodeTests {
    private func codes(_ pairs: [(UInt16, UInt32)]) -> [UInt32?] {
        pairs.map { MacKeyCode.evdev($0.0) }
    }

    @Test func lettersDigitsAndControls() {
        let pairs: [(UInt16, UInt32)] = [
            (0x00, 30), (0x01, 31), (0x0C, 16), (0x06, 44), (0x12, 2), (0x1D, 11), (0x24, 28),
            (0x30, 15), (0x31, 57), (0x33, 14), (0x35, 1), (0x75, 111), (0x7A, 59), (0x6F, 88),
            (0x69, 183), (0x5A, 190), (0x7B, 105), (0x7C, 106), (0x7D, 108), (0x7E, 103),
            (0x73, 102), (0x77, 107), (0x74, 104), (0x79, 109),
        ]
        #expect(codes(pairs) == pairs.map(\.1))
    }

    @Test func modifiers() {
        let pairs: [(UInt16, UInt32)] = [
            (0x38, 42), (0x3C, 54), (0x3B, 29), (0x3E, 97), (0x3A, 56), (0x3D, 100), (0x37, 125),
            (0x36, 126), (0x39, 58),
        ]
        #expect(codes(pairs) == pairs.map(\.1))
        // Fn is never sent: Fn-modified keys arrive as their own codes.
        #expect(MacKeyCode.evdev(0x3F) == nil)
    }

    /// Eisu and Kana as Linux reads a Mac JIS keyboard (HID LANG2/LANG1 → Hanja/Hangeul),
    /// which xkeyboard-config's `jp(mac)` binds to Eisu_toggle and Hiragana_Katakana.
    @Test func isoAndJIS() {
        let pairs: [(UInt16, UInt32)] = [
            (0x32, 41), (0x0A, 86), (0x5D, 124), (0x5E, 89), (0x5F, 95), (0x66, 123), (0x68, 122),
        ]
        #expect(codes(pairs) == pairs.map(\.1))
    }

    @Test func keypadAndMacOnly() {
        let pairs: [(UInt16, UInt32)] = [
            (0x4C, 96), (0x47, 69), (0x51, 117), (0x72, 110), (0x6E, 127), (0x48, 115), (0x49, 114),
            (0x4A, 113),
        ]
        #expect(codes(pairs) == pairs.map(\.1))
    }

    @Test func noTwoKeysShareACode() {
        // The table itself: looking every code up would log the unmapped ones.
        let mapped = Array(MacKeyCode.table.values)
        #expect(mapped.count == Set(mapped).count)
        #expect(mapped.count > 100)
    }

    @Test func isoSwap() {
        #expect(MacKeyCode.positional(0x32, isISO: true) == 0x0A)
        #expect(MacKeyCode.positional(0x0A, isISO: true) == 0x32)
        #expect(MacKeyCode.positional(0x32, isISO: false) == 0x32)
        #expect(MacKeyCode.positional(0x00, isISO: true) == 0x00)
    }
}
