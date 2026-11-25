internal import Foundation
internal import GliffTransport

/// The character rules for a macro's script, so what the approval sheet shows is what `sh`
/// reads: hidden characters are refused, and other characters outside printable ASCII are
/// shown escaped.
public enum MacroText {
    /// A refused character: its line (from 1) and its kind and code point, never the text
    /// around it.
    public struct Problem: Equatable, Sendable {
        public enum Kind: Sendable { case control, format, separator }
        public let line: Int
        public let kind: Kind
        public let codePoint: UInt32
    }

    /// Why `scalar` may not be in a script, or nil when it may: `SSHErrorClassifier.hidden`'s
    /// categories (control, format, line and paragraph separators), less `\n` and `\t`.
    static func refusal(of scalar: Unicode.Scalar) -> Problem.Kind? {
        guard scalar != "\n", scalar != "\t" else { return nil }
        let category = scalar.properties.generalCategory
        guard SSHErrorClassifier.hidden.contains(category) else { return nil }
        return switch category {
        case .format: .format
        case .lineSeparator, .paragraphSeparator: .separator
        default: .control
        }
    }

    /// Whether `script` has no refused character.
    public static func allows(_ script: String) -> Bool {
        !script.unicodeScalars.contains { refusal(of: $0) != nil }
    }

    /// Each refused character in `script`, in order, with its line, counted as a text view
    /// draws them: a line starts after `\n`, `\r\n`, a lone `\r`, U+0085, U+2028 or U+2029.
    public static func refused(in script: String) -> [Problem] {
        var problems: [Problem] = []
        var line = 1
        var afterReturn = false
        for scalar in script.unicodeScalars {
            if let kind = refusal(of: scalar) {
                problems.append(Problem(line: line, kind: kind, codePoint: scalar.value))
            }
            if lineBreaks.contains(scalar) && !(scalar == "\n" && afterReturn) { line += 1 }
            afterReturn = scalar == "\r"
        }
        return problems
    }

    /// What a text view draws as a line break.
    static let lineBreaks: Set<Unicode.Scalar> = ["\n", "\r", "\u{85}", "\u{2028}", "\u{2029}"]

    /// Whether the approval sheet shows `scalar` as it is.
    private static func showsAsIs(_ scalar: Unicode.Scalar) -> Bool {
        (0x20...0x7E).contains(scalar.value) || scalar == "\n" || scalar == "\t"
    }

    /// `script` as the approval sheet shows it: printable ASCII, `\n` and `\t` as they are,
    /// every other scalar as `\u{00A0}`; and how many were escaped. A typed `\` that starts
    /// `\u{`, or comes before an escaped scalar, is escaped too (`\u{005C}`), so typed text
    /// can't pass for an escape or hide one.
    public static func escapedForApproval(_ script: String) -> (text: String, escapedCount: Int) {
        let scalars = Array(script.unicodeScalars)
        // From the end, so a `\` sees whether the scalar after it is escaped, for any reason.
        var escaped = [Bool](repeating: false, count: scalars.count)
        for index in scalars.indices.reversed() {
            let scalar = scalars[index]
            let startsTypedEscape = scalars[(index + 1)...].starts(with: ["u", "{"])
            escaped[index] =
                !showsAsIs(scalar)
                || (scalar == "\\"
                    && (startsTypedEscape || (index + 1 < scalars.count && escaped[index + 1])))
        }
        var text = ""
        for (scalar, escape) in zip(scalars, escaped) {
            if escape {
                text += String(format: "\\u{%04X}", scalar.value)
            } else {
                text.unicodeScalars.append(scalar)
            }
        }
        return (text, escaped.count { $0 })
    }

    /// Pasted text with `\r\n` and lone `\r` turned into `\n`.
    public static func normalisingLineEnds(_ pasted: String) -> String {
        var text = String.UnicodeScalarView()
        var afterReturn = false
        for scalar in pasted.unicodeScalars {
            if scalar == "\r" {
                text.append("\n")
            } else if !(scalar == "\n" && afterReturn) {
                text.append(scalar)
            }
            afterReturn = scalar == "\r"
        }
        return String(text)
    }
}
