#if DEBUG
    import GliffSession
    import SwiftUI

    /// The Debug menu (Debug builds): Protocol Inspector (⌥⌘I), every window's frames counted;
    /// and for the key window's session, Record 5 Seconds… writes the raw stream to a .gliffrec
    /// for later replay, and Test Cursor Shape shows a known shape in place of the session's.
    struct DebugCommands: Commands {
        @FocusedValue(\.session) private var model
        @Environment(\.openWindow) private var openWindow

        var body: some Commands {
            CommandMenu("Debug") {
                Button("Protocol Inspector") { openWindow(id: "inspector") }
                    .keyboardShortcut("i", modifiers: [.command, .option])
                Divider()
                Button("Record 5 Seconds…") { model?.recordFiveSeconds() }
                    .disabled(model?.hasPicture != true)
                Divider()
                Toggle(
                    "Test Cursor Shape",
                    isOn: Binding(
                        get: { model?.testCursorShape ?? false }, set: { model?.testCursorShape = $0 })
                )
                .disabled(model == nil)
            }
        }
    }
#endif
