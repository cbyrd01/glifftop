import GliffSession
import SwiftUI

/// View ▸ Actual Size (⌘0, a mirror only; it turns Scale to Fit off), Scale to Fit (⌥⌘0), Show
/// Status Bar (⌘/), Text Size
/// and Resolution (a virtual screen only) and Screen. Everything they read changes only when its value does,
/// never with the stats each second: a View menu rebuilt every second loses Enter Full Screen.
struct ViewCommands: Commands {
    @Bindable var model: SessionModel
    @AppStorage(AppSettings.showsStatusBarKey) private var showsStatusBar = false

    var body: some Commands {
        CommandGroup(before: .toolbar) {
            // A virtual screen follows the window: there's no size of its own to return to.
            Button("Actual Size", action: model.actualSize)
                .keyboardShortcut("0")
                .disabled(!model.hasPicture || model.isVirtual)
            Toggle("Scale to Fit", isOn: $model.scaleToFit)
                .keyboardShortcut("0", modifiers: [.command, .option])
                .disabled(!model.hasPicture)
            Toggle("Show Status Bar", isOn: $showsStatusBar)
                .keyboardShortcut("/")
            Divider()
            TextSizeMenu(model: model)
            ResolutionMenu(model: model)
            ScreenMenu(model: model)
            Divider()
        }
    }
}
