import SwiftUI

/// The Connection menu: Disconnect (⇧⌘D), Reconnect (⇧⌘R: Reconnect Now, or Try Again), Connection Info (⌘I) and
/// Edit Machine… (⌘E, the session's machine once it has one); and File ▸ New Machine… (⌘N).
/// Everything it reads changes only with its value (`SessionModel+Chrome`), never with the
/// stats each second.
struct ConnectionCommands: Commands {
    let model: SessionModel

    var body: some Commands {
        CommandMenu("Connection") {
            Button("Disconnect", action: model.disconnect)
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(!model.canDisconnect)
            Button("Reconnect", action: model.reconnectNow)
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!model.canReconnect)
            Divider()
            Button("Connection Info") { model.showsConnectionInfo.toggle() }
                .keyboardShortcut("i")
                .disabled(!model.hasPicture)
            Button("Edit Machine…", action: model.editMachine)
                .keyboardShortcut("e")
                .disabled(!model.isActive || model.machine == nil)
        }
        CommandGroup(replacing: .newItem) {
            Button("New Machine…", action: model.newMachine)
                .keyboardShortcut("n")
        }
    }
}
