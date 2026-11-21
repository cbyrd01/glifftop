import Synchronization
import os

/// Mac virtual key codes (Carbon's kVK values, what `NSEvent.keyCode` reports) as Linux evdev
/// codes, what Gliff's `Key` carries (X11 keycode − 8). Keys are positions: the remote's XKB
/// keymap decides what each one types.
public enum MacKeyCode {
    /// The evdev code for `code`, or nil for a key that is never sent (Fn, or one the table
    /// doesn't know; each unknown code is logged once).
    public static func evdev(_ code: UInt16) -> UInt32? {
        if let evdev = table[code] { return evdev }
        if code != fn, unknown.withLock({ $0.insert(code).inserted }) {
            log.info("unmapped Mac key code \(code)")
        }
        return nil
    }

    /// The code for the key's position. On ISO keyboards macOS reports the key left of 1 and
    /// the key beside left Shift swapped (`kVK_ANSI_Grave` ↔ `kVK_ISO_Section`).
    public static func positional(_ code: UInt16, isISO: Bool) -> UInt16 {
        guard isISO else { return code }
        switch code {
        case grave: return isoSection
        case isoSection: return grave
        default: return code
        }
    }

    private static let grave: UInt16 = 0x32
    private static let isoSection: UInt16 = 0x0A
    private static let fn: UInt16 = 0x3F
    private static let unknown = Mutex<Set<UInt16>>([])
    private static let log = Logger(subsystem: "me.cbyrd.Glifftop", category: "GliffInput")

    static let table: [UInt16: UInt32] = [
        // Letters, A to Z.
        0x00: 30, 0x0B: 48, 0x08: 46, 0x02: 32, 0x0E: 18, 0x03: 33, 0x05: 34, 0x04: 35,
        0x22: 23, 0x26: 36, 0x28: 37, 0x25: 38, 0x2E: 50, 0x2D: 49, 0x1F: 24, 0x23: 25,
        0x0C: 16, 0x0F: 19, 0x01: 31, 0x11: 20, 0x20: 22, 0x09: 47, 0x0D: 17, 0x07: 45,
        0x10: 21, 0x06: 44,
        // Digits.
        0x12: 2, 0x13: 3, 0x14: 4, 0x15: 5, 0x17: 6, 0x16: 7, 0x1A: 8, 0x1C: 9, 0x19: 10,
        0x1D: 11,
        // Punctuation; 0x32 is the key left of 1 (grave), 0x0A the ISO key beside left Shift.
        0x1B: 12, 0x18: 13, 0x21: 26, 0x1E: 27, 0x29: 39, 0x27: 40, 0x32: 41, 0x2A: 43,
        0x2B: 51, 0x2F: 52, 0x2C: 53, 0x0A: 86,
        // Return, Tab, Space, Delete (Backspace), Esc.
        0x24: 28, 0x30: 15, 0x31: 57, 0x33: 14, 0x35: 1,
        // Modifiers: Shift, Control, Option (Alt), Command (Super), left then right; Caps Lock.
        0x38: 42, 0x3C: 54, 0x3B: 29, 0x3E: 97, 0x3A: 56, 0x3D: 100, 0x37: 125, 0x36: 126,
        0x39: 58,
        // F1–F12.
        0x7A: 59, 0x78: 60, 0x63: 61, 0x76: 62, 0x60: 63, 0x61: 64, 0x62: 65, 0x64: 66,
        0x65: 67, 0x6D: 68, 0x67: 87, 0x6F: 88,
        // F13–F20.
        0x69: 183, 0x6B: 184, 0x71: 185, 0x6A: 186, 0x40: 187, 0x4F: 188, 0x50: 189, 0x5A: 190,
        // Navigation: Help (in Insert's place), Home, Page Up, Forward Delete, End, Page Down.
        0x72: 110, 0x73: 102, 0x74: 104, 0x75: 111, 0x77: 107, 0x79: 109,
        // Arrows: left, right, down, up.
        0x7B: 105, 0x7C: 106, 0x7D: 108, 0x7E: 103,
        // Keypad 0–9.
        0x52: 82, 0x53: 79, 0x54: 80, 0x55: 81, 0x56: 75, 0x57: 76, 0x58: 77, 0x59: 71,
        0x5B: 72, 0x5C: 73,
        // Keypad . * + Clear (in Num Lock's place) / Enter - =.
        0x41: 83, 0x43: 55, 0x45: 78, 0x47: 69, 0x4B: 98, 0x4C: 96, 0x4E: 74, 0x51: 117,
        // JIS: Yen, Underscore (Ro), keypad comma; Eisu and Kana as Linux reads a Mac JIS keyboard
        // (Hanja, Hangeul), which `jp(mac)` binds to Eisu_toggle and Hiragana_Katakana.
        0x5D: 124, 0x5E: 89, 0x5F: 95, 0x66: 123, 0x68: 122,
        // Volume up, down, mute; Contextual Menu (Compose).
        0x48: 115, 0x49: 114, 0x4A: 113, 0x6E: 127,
    ]
}
