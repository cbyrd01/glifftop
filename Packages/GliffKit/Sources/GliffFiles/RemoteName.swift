import Foundation
import GliffTransport

/// One name in a host folder, as raw bytes: every operation on the host uses these.
///
/// - Never empty, `.` or `..`, and never holds `/` or NUL or more than 255 bytes (Linux allows
///   no longer).
/// - `shown` is what a person sees: control characters become pictures, and every other
///   character host text never shows as it came (`HostText`) becomes U+FFFD, so a name can't
///   reorder text or pass for another.
public struct RemoteName: Hashable, Sendable {
    public let raw: [UInt8]

    private static let maxBytes = 255

    public init?(raw: [UInt8]) {
        guard Self.isUsable(raw) else { return nil }
        self.raw = raw
    }

    /// A Mac name to upload, in NFC.
    public init?(uploading name: String) {
        self.init(raw: Array(name.precomposedStringWithCanonicalMapping.utf8))
    }

    /// Whether `raw` is `.` or `..`, which every folder lists and no item is called.
    public static func isDotEntry(_ raw: [UInt8]) -> Bool { raw == [0x2E] || raw == [0x2E, 0x2E] }

    /// Whether the name starts with `.`.
    public var isHidden: Bool { raw.first == 0x2E }

    /// The name decoded as UTF-8 with replacement characters; C0 controls and DEL become
    /// control pictures (U+2400 block), the rest of `HostText.isHidden` U+FFFD.
    public var shown: String {
        String(String.UnicodeScalarView(String(decoding: raw, as: UTF8.self).unicodeScalars.map(Self.shown)))
    }

    /// The name a downloaded item takes on this Mac: the shown form, nil when that isn't a
    /// usable name. Not unique: different host names can show alike, and this Mac folds case
    /// and normalization, so a download finds its clashes on this Mac's side.
    public var localName: String? {
        let shown = shown
        return Self.isUsable(Array(shown.utf8)) ? shown : nil
    }

    private static func isUsable(_ bytes: [UInt8]) -> Bool {
        !bytes.isEmpty && !isDotEntry(bytes) && bytes.count <= maxBytes && !bytes.contains(0x2F)
            && !bytes.contains(0)
    }

    private static func shown(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        switch scalar.value {
        case 0x00...0x1F: Unicode.Scalar(0x2400 + scalar.value) ?? replacement
        case 0x7F: "\u{2421}"
        default: HostText.isHidden(scalar) ? replacement : scalar
        }
    }

    private static let replacement: Unicode.Scalar = "\u{FFFD}"
}
