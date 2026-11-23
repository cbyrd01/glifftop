import SwiftUI

@main
struct GlifftopApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        // Each window or tab its own session (`SessionWindow`); none comes back at launch.
        WindowGroup(for: TabRequest.self) { $request in
            SessionWindow(request: request)
                .onAppear {
                    appDelegate.beforeQuit = {
                        await OpenSessions.shared.shutdownAll()
                        await AppConnections.closeAll()
                    }
                }
        } defaultValue: {
            TabRequest()
        }
        .restorationBehavior(.disabled)
        .windowResizability(.contentSize)
        // A remote desktop's height is the picture's: the toolbar takes as little as it can.
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            ConnectionCommands()
            ViewCommands()
            InputCommands()
            #if DEBUG
                DebugCommands()
            #endif
        }
        Settings {
            SettingsView()
        }
    }
}
