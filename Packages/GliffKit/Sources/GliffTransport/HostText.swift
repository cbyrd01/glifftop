/// The rule for text a host sends: what never shows as it came.
public enum HostText {
    /// Whether `scalar` is a control or format character (an escape code, a bidi override, a
    /// zero-width or tag character) or a line or paragraph break.
    public static func isHidden(_ scalar: Unicode.Scalar) -> Bool {
        // Printable ASCII, most of any host text, is never hidden.
        if (0x20...0x7E).contains(scalar.value) { return false }
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator: return true
        default: return false
        }
    }
}
