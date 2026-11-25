import AppKit
import GliffTransport

/// Lets quitting wait for async cleanup, such as the sessions' Bye and ssh's exit, before the
/// process ends. Closing the last window quits, so this covers both.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Run when the app is asked to quit; quitting waits for it to return.
    /// A second quit while one is waiting runs it again, which must be harmless.
    var beforeQuit: (() async -> Void)?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// The ssh sockets' folder is prepared now: the masters a Glifftop that crashed left
    /// signed in are ended at launch, not at the first connection.
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await SystemSSH.prepare() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // A paste on the Mac fetching from the remote ends first, without data.
        PasteProvider.cancelRunning()
        // Every session ends: none takes the host's clipboard from another.
        HostClipboards.shared.quitting = true
        guard let beforeQuit else { return .terminateNow }
        Task {
            await beforeQuit()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
