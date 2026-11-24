import GliffSession
import SwiftUI

/// View ▸ Actual Size (⌘0, a mirror only; it turns Scale to Fit off), Scale to Fit (⌥⌘0), Show
/// Status Bar (⌘/), Text Size and Resolution (a virtual screen only) and Screen, for the key
/// window's session. Everything they read changes only when its value does, never with the
/// stats each second: a View menu rebuilt every second loses Enter Full Screen.
struct ViewCommands: Commands {
    @FocusedValue(\.session) private var model
    @AppStorage(AppSettings.showsStatusBarKey) private var showsStatusBar = false

    var body: some Commands {
        CommandGroup(before: .toolbar) {
            // A virtual screen follows the window: there's no size of its own to return to. A
            // window shared with other tabs keeps the group's size.
            Button("Actual Size") { model?.actualSize() }
                .keyboardShortcut("0")
                .disabled(
                    model?.hasPicture != true || model?.isVirtual == true || model?.sharesWindow == true)
            Toggle(
                "Scale to Fit",
                isOn: Binding(get: { model?.scaleToFit ?? false }, set: { model?.scaleToFit = $0 })
            )
            .keyboardShortcut("0", modifiers: [.command, .option])
            // A mirror in a window shared with other tabs is drawn fitted already.
            .disabled(model?.hasPicture != true || model?.sharesWindow == true && model?.isVirtual == false)
            Toggle("Show Status Bar", isOn: $showsStatusBar)
                .keyboardShortcut("/")
            Divider()
            if let model {
                TextSizeMenu(model: model)
                ResolutionMenu(model: model)
                ScreenMenu(model: model)
            } else {
                Menu("Text Size") {}.disabled(true)
                Menu("Resolution") {}.disabled(true)
                Menu("Screen") {}.disabled(true)
            }
            Divider()
        }
    }
}
