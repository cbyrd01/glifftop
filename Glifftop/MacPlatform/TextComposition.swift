import AppKit

/// Text a field shows may not have reached its value: still being composed (an accent menu, an
/// input method), or put there by AutoFill. Committing it lets a form read what the field holds
/// right away; SwiftUI's binding may update later.
enum TextComposition {
    /// Commits any composing text in the key window's text view, where it stays, with the input
    /// method told it's done, and returns what the field then holds (a text field reads its
    /// editor while editing). Focus and the caret stay. Nil when no text is being edited.
    @MainActor static func commit() -> String? {
        guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return nil }
        if editor.hasMarkedText() {
            editor.unmarkText()
            editor.inputContext?.discardMarkedText()
        }
        return (editor.delegate as? NSTextField)?.stringValue ?? editor.string
    }
}
