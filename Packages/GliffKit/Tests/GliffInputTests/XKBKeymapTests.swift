import Testing

@testable import GliffInput

/// The keymap sent in Hello and Keymap: gliff-win's include-only text, which the server
/// compiles against its own xkeyboard-config.
@Suite struct XKBKeymapTests {
    @Test func exactText() {
        let expected = """
            xkb_keymap {
              xkb_keycodes { include "evdev+aliases(qwerty)" };
              xkb_types { include "complete+numpad(mac)" };
              xkb_compat { include "complete" };
              xkb_symbols { include "pc+gb(mac)+inet(evdev)" };
            };

            """
        #expect(XKBKeymap.text(for: XKBLayout(layout: "gb", variant: "mac")) == expected)
        #expect(XKBKeymap.text(for: XKBLayout(layout: "es")).contains("include \"pc+es+inet(evdev)\""))
    }

    @Test func symbols() {
        #expect(XKBLayout(layout: "ch", variant: "de_mac").symbols == "ch(de_mac)")
        #expect(XKBLayout(layout: "es").symbols == "es")
    }
}
