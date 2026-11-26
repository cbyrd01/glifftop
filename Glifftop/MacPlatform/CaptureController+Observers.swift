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
        // The pointer free while the app is still in front.
        observe(app, NSApplication.willResignActiveNotification) { $0.resign() }
        let workspace = NSWorkspace.shared.notificationCenter
        // Suspensions: another app activated (before this one resigns), another Space.
        // Not while this one is in front: its own activation, or a late notification of a quick
        // switch away and back.
        observe(workspace, NSWorkspace.didActivateApplicationNotification) {
            if !$0.isFrontmostApp { $0.leave() }
        }
        observe(workspace, NSWorkspace.activeSpaceDidChangeNotification) { $0.suspendConfinement() }
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
        // Any menu of the app open holds capture off. The tracker counts from the first
        // window's controller on, before any session.
        _ = MenuTracker.shared
        observe(app, MenuTracker.changed) { $0.apply(.menuOpen(MenuTracker.shared.isOpen)) }
    }

    func observeWindow() {
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers = []
        // A transition of another window (or one that failed) holds nothing here.
        transitionStarted = nil
        guard let window else { return }
        for (name, key) in [
            (NSWindow.didBecomeKeyNotification, true), (NSWindow.didResignKeyNotification, false),
        ] {
            observeWindow(window, name) { $0.apply(.windowKey(key)) }
        }
        // Suspensions: the window moves or changes size or screen (the frozen point would be
        // left elsewhere), or a sheet takes it.
        for name in [
            NSWindow.didMoveNotification, NSWindow.didResizeNotification,
            NSWindow.didChangeScreenNotification,
            NSWindow.willBeginSheetNotification,
        ] {
            observeWindow(window, name) { $0.suspendConfinement() }
        }
        // Full screen's transitions: no holding until each ends.
        for (name, on) in [
            (NSWindow.willEnterFullScreenNotification, true), (NSWindow.willExitFullScreenNotification, true),
            (NSWindow.didEnterFullScreenNotification, false), (NSWindow.didExitFullScreenNotification, false),
        ] {
            observeWindow(window, name) { $0.fullScreenTransition(on) }
        }
    }

    private func observeWindow(
        _ window: NSWindow, _ name: Notification.Name,
        _ action: @escaping @MainActor (CaptureController) -> Void
    ) {
        windowObservers.append(observer(NotificationCenter.default, name, object: window, action: action))
    }

    /// `action` on each `name` from `center`, for the controller's life.
    fileprivate func observe(
        _ center: NotificationCenter, _ name: Notification.Name,
        _ action: @escaping @MainActor (CaptureController) -> Void
    ) {
        observers.append((center, observer(center, name, action: action)))
    }

    private func observer(
        _ center: NotificationCenter, _ name: Notification.Name, object: AnyObject? = nil,
        action: @escaping @MainActor (CaptureController) -> Void
    ) -> any NSObjectProtocol {
        center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if let self { action(self) }
            }
        }
    }
}
