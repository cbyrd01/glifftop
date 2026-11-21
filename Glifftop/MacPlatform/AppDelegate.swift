import AppKit

/// Lets quitting wait for async cleanup, such as a session's Bye and ssh's exit, before the
/// process ends. Closing the app's only window quits it too, so this covers both.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Run when the app is asked to quit; quitting waits for it to return.
    /// A second quit while one is waiting runs it again, which must be harmless.
    var beforeQuit: (() async -> Void)?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // A paste on the Mac fetching from the remote ends first, without data.
        PasteProvider.cancelRunning()
        guard let beforeQuit else { return .terminateNow }
        Task {
            await beforeQuit()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
