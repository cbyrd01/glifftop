import AppKit
import GliffTransport

/// Lets quitting wait for async cleanup, such as the sessions' Bye and ssh's exit, before the
/// process ends. Closing the last window quits, so this covers both. While a session is live,
/// ⌘Q pressed must be held (`QuitGuard`).
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Run when the app is asked to quit; quitting waits for it to return.
    /// A second quit while one is waiting runs it again, which must be harmless.
    var beforeQuit: (() async -> Void)?
    /// Whether ⌘Q is guarded now: a session is live in some window (connecting, streaming,
    /// interrupted or reconnecting).
    var guardsQuit: () -> Bool = { false }
    private let quitGuard = QuitGuard()

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// The ssh sockets' folder is prepared now: the masters a Glifftop that crashed left
    /// signed in are ended at launch, not at the first connection.
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await SystemSSH.prepare() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if quitGuard.holdsBack(NSApp.currentEvent, guarded: guardsQuit()) { return .terminateCancel }
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
