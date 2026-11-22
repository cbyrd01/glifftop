import AppKit
import GliffClipboard

/// The Mac pasteboard's types as the remote's mime types, and back. Files aren't
/// shared: a Finder copy offers only its names, as text.
nonisolated enum PasteboardTypes {
    /// What password managers mark their copies with (nspasteboard.org); a remote password
    /// goes on the Mac marked concealed.
    static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    /// The mime types to offer for a pasteboard holding `types`: the text flavours for text,
    /// `text/html` for HTML, `image/png` for PNG or TIFF; nothing else.
    static func mimes(for types: [NSPasteboard.PasteboardType]) -> [String] {
        var mimes = types.contains(.string) ? ClipboardMimes.textFlavours : []
        // A Finder copy: its names as text, never its icon as a picture.
        guard !types.contains(.fileURL) else { return mimes }
        if types.contains(.html) { mimes.append(ClipboardMimes.html) }
        if types.contains(.png) || types.contains(.tiff) { mimes.append(ClipboardMimes.png) }
        return mimes
    }

    /// Whether a password manager marked the copy concealed or transient: it is offered only
    /// while the clipboard is shared including passwords, and then with KDE's marker, so the host's clipboard history
    /// doesn't keep it.
    static func isPassword(_ types: [NSPasteboard.PasteboardType]) -> Bool {
        types.contains(concealed) || types.contains(transient)
    }

    /// The Mac types a remote offer of `mimes` is put on the pasteboard as: text, HTML, PNG.
    static func types(forRemote mimes: [String]) -> [NSPasteboard.PasteboardType] {
        [.string, .html, .png].filter { remoteMime(for: $0, in: mimes) != nil }
    }

    /// The remote's type a paste of `type` fetches: its best text flavour for text.
    static func remoteMime(for type: NSPasteboard.PasteboardType, in offered: [String]) -> String? {
        let wanted: String? =
            switch type {
            case .string: ClipboardMimes.text
            case .html: ClipboardMimes.html
            case .png: ClipboardMimes.png
            default: nil
            }
        return wanted.flatMap { ClipboardMimes.resolve($0, in: offered) }
    }

    /// The pasteboard type a remote request for `mime` reads (an image may need TIFF instead).
    static func pasteboardType(for mime: String) -> NSPasteboard.PasteboardType? {
        if ClipboardMimes.isText(mime) { return .string }
        return switch mime {
        case ClipboardMimes.html: .html
        case ClipboardMimes.png: .png
        default: nil
        }
    }
}
