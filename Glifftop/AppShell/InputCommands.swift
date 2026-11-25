import SwiftUI

/// Input ▸ Release Input (⇧⎋), while the key window's input (keys and pointer) is captured, or
/// held off only by an open menu (this one, while the item is chosen). A menu of its own, so
/// the View menu (and the Enter Full Screen item macOS adds to it) is left alone. While
/// captured, Shift+Esc itself reaches the capture controller first; the item shows the
/// shortcut and works by mouse.
struct InputCommands: Commands {
    @FocusedValue(\.session) private var model

    var body: some Commands {
        CommandMenu("Input") {
            Button("Release Input") { model?.capture.release() }
                .keyboardShortcut(.escape, modifiers: .shift)
                .disabled(model?.capture.isReleasable != true)
        }
    }
}
