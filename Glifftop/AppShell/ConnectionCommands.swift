import SwiftUI

/// The Connection menu: Disconnect (⇧⌘D), Reconnect (⇧⌘R), Connection Info (⌘I) and Edit
/// Machine… (⌘E); Reconnect and Edit Machine… are disabled.
/// Everything it reads changes only with its value (`SessionModel+Chrome`), never with the
/// stats each second.
struct ConnectionCommands: Commands {
    let model: SessionModel

    var body: some Commands {
        CommandMenu("Connection") {
            Button("Disconnect", action: model.disconnect)
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(!model.canDisconnect)
            Button("Reconnect") {}
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(true)
            Divider()
            Button("Connection Info") { model.showsConnectionInfo.toggle() }
                .keyboardShortcut("i")
                .disabled(!model.hasPicture)
            Button("Edit Machine…") {}
                .keyboardShortcut("e")
                .disabled(true)
        }
    }
}
