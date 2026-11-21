import Foundation

/// Upstream's mime rules (gliff-proto `clipboard.rs`): which types are worth offering, and which
/// offered type answers a request.
public enum ClipboardMimes {
    /// The type the pasting side uses for text received as any text flavour.
    public static let text = "text/plain;charset=utf-8"
    /// The text flavours, best first; interchangeable.
    public static let textFlavours = [text, "text/plain", "UTF8_STRING", "STRING", "TEXT"]
    public static let html = "text/html"
    public static let png = "image/png"
    public static let uriList = "text/uri-list"
    public static let gnomeFiles = "x-special/gnome-copied-files"
    /// KDE's marker for a password, which clipboard histories skip.
    public static let passwordHint = "x-kde-passwordManagerHint"

    private static let fileMimes: Set = [uriList, gnomeFiles]
    /// X11 selection atoms that name no data.
    private static let nonDataTargets: Set = [
        "TARGETS", "TIMESTAMP", "MULTIPLE", "SAVE_TARGETS", "DELETE", "INSERT_PROPERTY",
        "INSERT_SELECTION",
    ]

    /// The types worth advertising: real data types, without the file-list types (files aren't
    /// shared), each once, and every text flavour first if any is there.
    public static func forwardable(_ offered: [String]) -> [String] {
        var out: [String] = []
        var hadText = false
        for raw in offered {
            let mime = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if mime.isEmpty || nonDataTargets.contains(mime) || isFile(mime)
                || mime.contains(where: \.isWhitespace)
            {
                continue
            }
            if isText(mime) {
                hadText = true
            } else if !out.contains(mime) {
                out.append(mime)
            }
        }
        return hadText ? textFlavours + out : out
    }

    public static func isText(_ mime: String) -> Bool { textFlavours.contains(mime) }

    public static func isFile(_ mime: String) -> Bool { fileMimes.contains(mime) }

    /// The offered type that answers a request: the exact type, else the best text flavour
    /// offered for a text request.
    public static func resolve(_ requested: String, in offered: [String]) -> String? {
        if let exact = offered.first(where: { $0 == requested }) { return exact }
        guard isText(requested) else { return nil }
        return textFlavours.first(where: offered.contains)
    }
}
