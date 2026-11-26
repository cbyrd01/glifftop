import GliffInput
import SwiftUI

/// The Connection menu: Disconnect (⇧⌘D), Reconnect (⇧⌘R: Reconnect Now, or Try Again), Connection
/// Info (⌘I), Show Ports (⌥⌘P, `PortsCommands`) and Edit Machine… (⌘E, the session's machine once
/// it has one); and in File, New Tab
/// (⌘T, disabled while the window shows one of its model's sheets), New Window (⌘N), New
/// Machine… (⌥⌘N) and Close Window (⇧⌘W, every tab of the window); in Window, Previous Tab
/// (⇧⌘[) and Next Tab (⇧⌘]), to the next window when the window has one tab.
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
            PortsCommands(model: model)
            Button("Edit Machine…") { model?.editMachine() }
                .keyboardShortcut("e")
                .disabled(model?.isActive != true || model?.machine == nil)
        }
        CommandGroup(replacing: .newItem) {
            // The key session window's group; without one, a window of its own.
            Button("New Tab") {
                let tabOf = model?.tabGroup?.window
                openWindow(value: TabRequest(tabOf: tabOf, alone: tabOf == nil, host: model?.host))
            }
            .keyboardShortcut("t")
            // A window with a sheet can't take a tab (`WindowTabbing`).
            .disabled(model?.showsSheet == true)
            Button("New Window") { openWindow(value: TabRequest(alone: true)) }
                .keyboardShortcut("n")
            Button("New Machine…") { model?.newMachine() }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(model == nil)
        }
        CommandGroup(before: .windowArrangement) {
            // Over a picture, the window's key monitor takes the chord first (`CaptureController`).
            tabButton("Previous Tab", .previous, key: "[")
            tabButton("Next Tab", .next, key: "]")
            Divider()
        }
        CommandGroup(after: .saveItem) {
            Button("Close Window", action: WindowTabbing.closeKeyWindowGroup)
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(model == nil)
        }
    }

    private func tabButton(_ title: String, _ chord: TabChord, key: KeyEquivalent) -> some View {
        Button(title) { OpenSessions.shared.selectTab(chord, from: model?.tabGroup?.window) }
            .keyboardShortcut(key, modifiers: [.command, .shift])
            .disabled(OpenSessions.shared.models.count < 2)
    }
}
