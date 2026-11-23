import SwiftUI

/// The Connection menu: Disconnect (⇧⌘D), Reconnect (⇧⌘R: Reconnect Now, or Try Again), Connection
/// Info (⌘I) and Edit Machine… (⌘E, the session's machine once it has one); and in File, New Tab
/// (⌘T), New Window (⌘N), New Machine… (⌥⌘N) and Close Window (⇧⌘W, every tab of the window).
/// They act on the key window's session, disabled without one. Everything they read changes only
/// with its value (`SessionModel+Chrome`), never with the stats each second.
struct ConnectionCommands: Commands {
    @FocusedValue(\.session) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("Connection") {
            Button("Disconnect") { model?.backToMachines() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(model?.canDisconnect != true)
            Button("Reconnect") { model?.reconnectNow() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model?.canReconnect != true)
            Divider()
            Button("Connection Info") { model?.showsConnectionInfo.toggle() }
                .keyboardShortcut("i")
                .disabled(model?.hasPicture != true)
            Button("Edit Machine…") { model?.editMachine() }
                .keyboardShortcut("e")
                .disabled(model?.isActive != true || model?.machine == nil)
        }
        CommandGroup(replacing: .newItem) {
            // The key session window's group; without one, a window of its own.
            Button("New Tab") { openWindow(value: TabRequest(tabOf: model?.tabGroup?.window)) }
                .keyboardShortcut("t")
            Button("New Window") { openWindow(value: TabRequest()) }
                .keyboardShortcut("n")
            Button("New Machine…") { model?.newMachine() }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(model == nil)
        }
        CommandGroup(after: .saveItem) {
            Button("Close Window", action: WindowTabbing.closeKeyWindowGroup)
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(model == nil)
        }
    }
}
