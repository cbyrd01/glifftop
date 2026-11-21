import Foundation
import Testing

@testable import GliffInput

/// macOS input sources to XKB layouts: the Mac variant where xkeyboard-config has one (what
/// is printed on the keys), the plain layout otherwise, `us` when unknown.
@Suite struct KeyboardLayoutTableTests {
    private func symbols(_ name: String) -> String {
        KeyboardLayoutTable.layout(forInputSource: "com.apple.keylayout.\(name)").symbols
    }

    @Test func macVariants() {
        #expect(symbols("British") == "gb(mac)")
        #expect(symbols("German") == "de(mac)")
        #expect(symbols("SwissGerman") == "ch(de_mac)")
        #expect(symbols("US") == "us(mac)")
        #expect(symbols("ABC") == "us(mac)")
        #expect(symbols("Dvorak") == "us(dvorak-mac)")
    }

    @Test func plainWhereNoMacVariant() {
        #expect(symbols("Spanish") == "es")
        #expect(symbols("PolishPro") == "pl")
    }

    /// macOS's PC layouts type as Linux's plain ones (British – PC: ⇧2 is ", ⇧' is @).
    @Test func pcLayoutsArePlain() {
        #expect(symbols("British-PC") == "gb")
        #expect(symbols("French-PC") == "fr")
    }

    /// The letter arrangement decides: macOS's `Italian` is QZERTY (as `it(mac)` is),
    /// `Italian-Pro` QWERTY; `Polish` is QWERTZ; ABC – QWERTZ and ABC – AZERTY type as German
    /// and French do (checked with UCKeyTranslate).
    @Test func letterArrangements() {
        #expect(symbols("Italian") == "it(mac)")
        #expect(symbols("Italian-Pro") == "it")
        #expect(symbols("Polish") == "pl(qwertz)")
        #expect(symbols("Hungarian-QWERTY") == "hu(qwerty)")
        #expect(symbols("ABC-QWERTZ") == "de(mac)")
        #expect(symbols("ABC-AZERTY") == "fr(mac)")
    }

    @Test func otherCommonLayouts() {
        let expected = [
            "Colemak": "us(colemak)", "DVORAK-QWERTYCMD": "us(dvorak-mac)", "Dvorak-Left": "us(dvorak-l)",
            "Dvorak-Right": "us(dvorak-r)", "USExtended": "us(mac)", "USInternational-PC": "us(intl)",
            "Canadian": "us(mac)", "RussianWin": "ru", "Ukrainian-PC": "ua", "Ukrainian": "ua(macOS)",
            "Turkish-Standard": "tr(f)", "Croatian-PC": "hr", "Slovak": "sk", "Slovak-QWERTY": "sk(qwerty)",
            "Brazilian-Pro": "br",
        ]
        for (name, symbols) in expected { #expect(self.symbols(name) == symbols, "\(name)") }
    }

    /// Layouts matched by what each key types, plain and shifted (UCKeyTranslate against the
    /// test host's xkeyboard-config): the letters match; at most a symbol or two differ.
    @Test func moreLatinLayouts() {
        let expected = [
            "French-numerical": "fr(mac)", "German-DIN-2137": "de(mac)", "Croatian": "si(us)",
            "Slovenian": "si(us)", "Slovenian-QWERTZ": "si", "Serbian-Latin": "rs(latinyz)",
            "Romanian": "ro", "Romanian-Standard": "ro(std)", "Estonian": "ee",
            "Latvian": "lv(apostrophe)", "Lithuanian": "lt", "Turkish": "tr(f)", "Turkish-QWERTY": "tr(alt)",
        ]
        for (name, symbols) in expected {
            #expect(self.symbols(name) == symbols, "\(name)")
        }
    }

    /// Only Apple's own layouts are known by name: another vendor's "German" could be anything.
    @Test func otherVendorsAreUS() {
        #expect(
            KeyboardLayoutTable.layout(forInputSource: "org.example.keylayout.German")
                == KeyboardLayoutTable.fallback)
    }

    @Test func noNameIsListedTwice() {
        let names = KeyboardLayoutTable.table.flatMap(\.names)
        #expect(names.count == Set(names).count)
    }

    @Test func unknownSourcesAreUS() {
        for id in ["com.apple.keylayout.Klingon", "", "com.apple.inputmethod.Kotoeri"] {
            #expect(KeyboardLayoutTable.layout(forInputSource: id) == KeyboardLayoutTable.fallback, "\(id)")
        }
        #expect(KeyboardLayoutTable.fallback == XKBLayout(layout: "us"))
    }

    @Test func everyRowIsWellFormed() throws {
        let layout = try Regex("^[a-z]{2,5}$")
        let variant = try Regex("^[A-Za-z_-]+$")
        for (name, row) in KeyboardLayoutTable.rows {
            #expect(row.layout.wholeMatch(of: layout) != nil, "\(name)")
            if let v = row.variant { #expect(v.wholeMatch(of: variant) != nil, "\(name)") }
        }
        #expect(KeyboardLayoutTable.rows.count >= 40)
    }
}
