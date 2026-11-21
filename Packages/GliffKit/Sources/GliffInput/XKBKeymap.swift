/// An XKB layout and variant, as xkeyboard-config names them.
public struct XKBLayout: Sendable, Equatable {
    public var layout: String
    public var variant: String?

    public init(layout: String, variant: String? = nil) {
        self.layout = layout
        self.variant = variant
    }

    /// `layout` or `layout(variant)`, the form an `xkb_symbols` include takes.
    public var symbols: String {
        variant.map { "\(layout)(\($0))" } ?? layout
    }
}

/// The keymap text Hello and Keymap carry: gliff-win's include-only keymap, which
/// the server compiles against its own xkeyboard-config. Key codes stay positions; only the
/// symbols name the layout. `numpad(mac)` types: the keypad types digits with no NumLock, as
/// a Mac's does (a Mac has no NumLock key, and the remote's virtual keyboard starts with none).
public enum XKBKeymap {
    public static func text(for layout: XKBLayout) -> String {
        """
        xkb_keymap {
          xkb_keycodes { include "evdev+aliases(qwerty)" };
          xkb_types { include "complete+numpad(mac)" };
          xkb_compat { include "complete" };
          xkb_symbols { include "pc+\(layout.symbols)+inet(evdev)" };
        };

        """
    }
}
