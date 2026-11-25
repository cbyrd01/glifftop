import AppKit
import GliffInput

/// What capture depends on outside the session: the app, the workspace, the screen lock, the
/// input source and the window's key state.
extension CaptureController {
    /// The app, workspace and distributed observers, for the controller's life.
    func observeApp() {
        let app = NotificationCenter.default
        observe(app, NSApplication.didBecomeActiveNotification) { $0.apply(.appActive(true)) }
        observe(app, NSApplication.didResignActiveNotification) { $0.apply(.appActive(false)) }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
            NSWorkspace.sessionDidResignActiveNotification,
        ] {
            observe(workspace, name) { $0.apply(.away) }
        }
        // Back from sleep, a lock or another user: the host's focus again, if still captured.
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observe(workspace, name) { $0.reactivate() }
        }
        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.apply(.away) }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { $0.reactivate() }
        observe(distributed, InputSource.changed) { $0.keymapChanged() }
    }

    func observeWindow() {
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers = []
        guard let window else { return }
        for (name, key) in [
            (NSWindow.didBecomeKeyNotification, true), (NSWindow.didResignKeyNotification, false),
        ] {
            windowObservers.append(
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) {
                    [weak self] _ in
                    MainActor.assumeIsolated { self?.apply(.windowKey(key)) }
                })
        }
    }

    fileprivate func observe(
        _ center: NotificationCenter, _ name: Notification.Name,
        _ action: @escaping @MainActor (CaptureController) -> Void
    ) {
        let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if let self { action(self) }
            }
        }
        observers.append((center, observer))
    }
}
