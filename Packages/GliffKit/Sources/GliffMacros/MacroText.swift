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

    /// Each refused character in `script`, in order, with its line.
    public static func refused(in script: String) -> [Problem] {
        var problems: [Problem] = []
        var line = 1
        for scalar in script.unicodeScalars {
            if let kind = refusal(of: scalar) {
                problems.append(Problem(line: line, kind: kind, codePoint: scalar.value))
            }
            if scalar == "\n" { line += 1 }
        }
        return problems
    }

    /// `script` as the approval sheet shows it: printable ASCII, `\n` and `\t` as they are,
    /// every other scalar as `\u{00A0}`; and how many were escaped. A typed `\` that starts
    /// `\u{` is escaped too (`\u{005C}`), so typed text can't pass for an escape.
    public static func escapedForApproval(_ script: String) -> (text: String, escapedCount: Int) {
        var text = ""
        var count = 0
        let scalars = Array(script.unicodeScalars)
        for (index, scalar) in scalars.enumerated() {
            let startsEscape = scalar == "\\" && scalars[(index + 1)...].starts(with: ["u", "{"])
            if !startsEscape && ((0x20...0x7E).contains(scalar.value) || scalar == "\n" || scalar == "\t") {
                text.unicodeScalars.append(scalar)
            } else {
                text += String(format: "\\u{%04X}", scalar.value)
                count += 1
            }
        }
        return (text, count)
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
