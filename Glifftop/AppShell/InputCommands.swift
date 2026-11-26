import GliffInput
import SwiftUI

/// The Input menu: the key window's mode (Integrated or Capture, radio items; disabled without
/// a session window), then Release Input (⇧⎋), while its input (keys and pointer) is captured,
/// or held off only by an open menu (this one, while the item is chosen). A menu of its own, so
/// the View menu (and the Enter Full Screen item macOS adds to it) is left alone. While
/// captured, Shift+Esc itself reaches the capture controller first; the item shows the
/// shortcut and works by mouse.
struct InputCommands: Commands {
    @FocusedValue(\.session) private var model

    var body: some Commands {
        CommandMenu("Input") {
            Picker("Mode", selection: mode) {
                ForEach(CaptureMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            .disabled(model == nil)
            Divider()
            Button("Release Input") { model?.capture.release() }
                .keyboardShortcut(.escape, modifiers: .shift)
                .disabled(model?.capture.isReleasable != true)
        }
    }

    /// The key window's mode; Integrated shown without one.
    private var mode: Binding<CaptureMode> {
        Binding(
            get: { model?.capture.mode ?? .integrated },
            set: { model?.capture.mode = $0 })
    }
}
