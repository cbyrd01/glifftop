import SwiftUI

/// Input ▸ Release Input (⇧⎋), while input (keys and pointer) is captured. A menu of its own,
/// so the View menu (and the Enter Full Screen item macOS adds to it) is left alone; the later
/// capture modes join it. While captured, Shift+Esc itself reaches the capture controller
/// first; the item shows the shortcut and works by mouse.
struct InputCommands: Commands {
    let model: SessionModel

    var body: some Commands {
        CommandMenu("Input") {
            Button("Release Input", action: model.capture.release)
                .keyboardShortcut(.escape, modifiers: .shift)
                .disabled(!model.capture.isCaptured)
        }
    }
}
