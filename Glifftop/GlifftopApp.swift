import SwiftUI

@main
struct GlifftopApp: App {
    @State private var model = SessionModel()
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        Window("Glifftop", id: "main") {
            RootView(model: model)
                .onAppear { appDelegate.beforeQuit = model.shutdown }
        }
        .windowResizability(.contentSize)
        .commands {
            ViewCommands(model: model)
            InputCommands(model: model)
            #if DEBUG
                DebugCommands(model: model)
            #endif
        }
        Settings {
            SettingsView()
        }
    }
}
