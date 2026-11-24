import AppKit

/// Which host's copy is on the Mac clipboard, when a session put it there: the pasteboard's
/// count after the write, and the destination as typed. Every window's controller reads it, so
/// a copy from one host is never offered back to that host by another window to it.
@MainActor enum ClipboardOrigin {
    private static var last: (changeCount: Int, destination: String)?

    static func record(changeCount: Int, destination: String) {
        last = (changeCount, destination)
    }

    /// The destination whose session wrote the clipboard at `changeCount`; nil for a Mac copy.
    static func destination(of changeCount: Int) -> String? {
        last.flatMap { $0.changeCount == changeCount ? $0.destination : nil }
    }
}
