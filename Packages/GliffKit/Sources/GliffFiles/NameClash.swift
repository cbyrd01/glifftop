import Foundation

/// Finder's way with a name already taken, and the Mac's sense of when two names are the same.
public enum NameClash {
    static let maxTries = 1_000

    /// The first of `name`, "name 2", "name 3"… that `exists` says is free, the number going
    /// before the last extension (not for a folder or a name whose only dot leads), the stem
    /// cut so the name fits 255 bytes; nil after 1,000 tries.
    public static func nextFree<Failure: Error>(
        _ name: String, isFolder: Bool, exists: (String) async throws(Failure) -> Bool
    ) async throws(Failure) -> String? {
        guard try await exists(name) else { return name }
        for number in 2...maxTries {
            let candidate = numbered(name, number, isFolder: isFolder)
            if try await !exists(candidate) { return candidate }
        }
        return nil
    }

    static func numbered(_ name: String, _ number: Int, isFolder: Bool) -> String {
        var stem = Substring(name)
        var suffix = " \(number)"
        if !isFolder, let dot = name.lastIndex(of: "."), dot != name.startIndex,
            name[dot...].utf8.count + suffix.utf8.count < 255
        {
            stem = name[..<dot]
            suffix += name[dot...]
        }
        while stem.utf8.count + suffix.utf8.count > 255 { stem.removeLast() }
        return stem + suffix
    }

    /// The form under which this Mac's file system takes two names as one: case folded and
    /// canonically decomposed, so `Makefile` and `makefile` collide, as do NFC and NFD forms.
    public static func caseFolded(_ name: String) -> String {
        name.folding(options: .caseInsensitive, locale: nil).decomposedStringWithCanonicalMapping
    }
}
