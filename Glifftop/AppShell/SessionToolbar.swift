import SwiftUI

/// The session's controls in the window's toolbar, in three groups: the screen (and a virtual
/// screen's text size), the shared clipboard, and Connection Info and Disconnect. Hidden while
/// no session is shown; each is in the menu bar too.
struct SessionToolbar: ToolbarContent {
    @Bindable var model: SessionModel

    var body: some ToolbarContent {
        ToolbarItem { ScreenMenu(model: model) }
            .hidden(!model.isActive)
        ToolbarItem { TextSizeMenu(model: model) }
            .hidden(!model.isActive || !model.isVirtual)
        ToolbarSpacer(.fixed)
            .hidden(!model.isActive)
        ToolbarItem { ClipboardToolbarItem(model: model) }
            .hidden(!model.isActive)
        ToolbarSpacer(.fixed)
            .hidden(!model.isActive)
        ToolbarItemGroup {
            Button("Connection Info", systemImage: "info.circle") { model.showsConnectionInfo.toggle() }
                .disabled(!model.hasPicture)
            Button("Disconnect", systemImage: "power", action: model.disconnect)
                .disabled(!model.canDisconnect)
        }
        .hidden(!model.isActive)
    }
}
