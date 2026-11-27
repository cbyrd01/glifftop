import AppKit
import os

/// Whether any of the app's menus is being tracked (the menu bar's, a toolbar pull-down's, a
/// context menu's): counts `NSMenu`'s tracking begins against its ends, once for the app, and
/// posts `changed` when the first opens or the last closes.
@MainActor final class MenuTracker {
    static let shared = MenuTracker()
    /// Posted on the default centre when `isOpen` changes.
    static let changed = Notification.Name("io.github.cbyrd01.Glifftop.MenuTracker.changed")
    private static let logger = Logger(subsystem: "io.github.cbyrd01.Glifftop", category: "input")

    private var open = 0
    var isOpen: Bool { open > 0 }

    private init() {
        for (name, began) in [
            (NSMenu.didBeginTrackingNotification, true), (NSMenu.didEndTrackingNotification, false),
        ] {
            // For the app's life: never removed.
            _ = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { MenuTracker.shared.tracking(began: began) }
            }
        }
        // No menu stays open once the app is inactive: a begin whose end never came is
        // forgotten there, so it can't hold capture off for good.
        _ = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { MenuTracker.shared.reset() }
        }
    }

    private func reset() {
        guard open > 0 else { return }
        Self.logger.debug("menu tracking reset, open \(self.open)")
        open = 0
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    private func tracking(began: Bool) {
        let wasOpen = isOpen
        open = max(0, open + (began ? 1 : -1))
        Self.logger.debug("menu tracking \(began ? "began" : "ended", privacy: .public), open \(self.open)")
        if isOpen != wasOpen { NotificationCenter.default.post(name: Self.changed, object: nil) }
    }
}
