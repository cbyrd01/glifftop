#if DEBUG
    import GliffSession
    import SwiftUI

    /// The Debug menu (Debug builds): Record 5 Seconds… writes the raw stream to a .gliffrec for
    /// later replay; Test Cursor Shape shows a known shape in place of the session's.
    struct DebugCommands: Commands {
        @Bindable var model: SessionModel

        var body: some Commands {
            CommandMenu("Debug") {
                Button("Record 5 Seconds…", action: model.recordFiveSeconds)
                    .disabled(!model.hasPicture)
                Divider()
                Toggle("Test Cursor Shape", isOn: $model.testCursorShape)
            }
        }
    }
#endif
