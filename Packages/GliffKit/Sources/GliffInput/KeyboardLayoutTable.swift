/// macOS keyboard layouts (input source ids, `com.apple.keylayout.<name>`) as XKB layouts. The
/// Mac variant where xkeyboard-config has one, so the remote types what is printed on the
/// keys; those variants make right ⌥ the remote's AltGr. The plain layout where there is none,
/// `us` for anything unknown. Japanese input methods type through `ABC`, so a JIS keyboard gets
/// `us(mac)`. Each row names a layout and variant in xkeyboard-config's symbols.
public enum KeyboardLayoutTable {
    /// Anything unknown (another vendor's layout, an input method): plain US.
    public static let fallback = XKBLayout(layout: "us")

    public static func layout(forInputSource id: String) -> XKBLayout {
        let prefix = "com.apple.keylayout."
        guard id.hasPrefix(prefix) else { return fallback }
        return rows[String(id.dropFirst(prefix.count))] ?? fallback
    }

    static let rows: [String: XKBLayout] = {
        var rows: [String: XKBLayout] = [:]
        for (names, layout, variant) in table {
            for name in names { rows[name] = XKBLayout(layout: layout, variant: variant) }
        }
        return rows
    }()

    /// Ids as macOS 27 lists them (TISCreateInputSourceList). A layout's letters and symbols
    /// decide its row, not its name: macOS's `Italian` is QZERTY and `Polish` QWERTZ, and its
    /// PC layouts type as Linux's plain ones.
    static let table: [(names: [String], layout: String, variant: String?)] = [
        // Mac variants.
        (["US", "ABC", "USExtended", "Canadian"], "us", "mac"),
        (["Dvorak", "DVORAK-QWERTYCMD"], "us", "dvorak-mac"),
        (["British"], "gb", "mac"),
        (["German", "ABC-QWERTZ", "German-DIN-2137"], "de", "mac"),
        (["Austrian"], "at", "mac"),
        (["SwissGerman"], "ch", "de_mac"),
        (["SwissFrench"], "ch", "fr_mac"),
        (["French", "ABC-AZERTY", "French-numerical"], "fr", "mac"),
        (["Italian"], "it", "mac"),
        (["Portuguese"], "pt", "mac"),
        (["Dutch"], "nl", "mac"),
        (["Swedish", "Swedish-Pro"], "se", "mac"),
        (["Norwegian"], "no", "mac"),
        (["Danish"], "dk", "mac"),
        (["Finnish"], "fi", "mac"),
        (["Icelandic"], "is", "mac"),
        (["Czech-QWERTY"], "cz", "qwerty-mac"),
        (["Russian"], "ru", "mac"),
        (["Ukrainian"], "ua", "macOS"),
        // Other variants.
        (["Colemak"], "us", "colemak"),
        (["Dvorak-Left"], "us", "dvorak-l"),
        (["Dvorak-Right"], "us", "dvorak-r"),
        (["USInternational-PC"], "us", "intl"),
        (["Polish"], "pl", "qwertz"),
        (["Hungarian-QWERTY"], "hu", "qwerty"),
        (["Slovak-QWERTY"], "sk", "qwerty"),
        (["Turkish-Standard", "Turkish"], "tr", "f"),
        (["Turkish-QWERTY"], "tr", "alt"),
        // QWERTY with š đ č ć ž on their own keys.
        (["Croatian", "Slovenian"], "si", "us"),
        (["Serbian-Latin"], "rs", "latinyz"),
        (["Romanian-Standard"], "ro", "std"),
        (["Latvian"], "lv", "apostrophe"),
        // The plain layout.
        (["British-PC"], "gb", nil),
        (["French-PC"], "fr", nil),
        (["Italian-Pro"], "it", nil),
        (["Spanish", "Spanish-ISO"], "es", nil),
        (["Belgian"], "be", nil),
        (["LatinAmerican"], "latam", nil),
        (["PolishPro"], "pl", nil),
        (["Czech"], "cz", nil),
        (["Slovak"], "sk", nil),
        (["Croatian-PC"], "hr", nil),
        (["Slovenian-QWERTZ"], "si", nil),
        (["Romanian"], "ro", nil),
        (["Estonian"], "ee", nil),
        (["Lithuanian"], "lt", nil),
        (["Hungarian"], "hu", nil),
        (["Brazilian", "Brazilian-ABNT2", "Brazilian-Pro"], "br", nil),
        (["CanadianFrench-PC"], "ca", nil),
        (["Turkish-QWERTY-PC"], "tr", nil),
        (["RussianWin"], "ru", nil),
        (["Ukrainian-PC"], "ua", nil),
        (["Irish"], "ie", nil),
        (["Australian"], "au", nil),
    ]
}
