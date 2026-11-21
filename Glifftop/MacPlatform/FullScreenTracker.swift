import AppKit
import SwiftUI
import os

/// The window's full-screen state, for SwiftUI, and leaving full screen when the picture goes:
/// a full-screen window would show the compact screens as a small box on black.
///
/// RootView keeps its content free to grow while the window is full screen. Content that
/// can't grow (fixed, or no bigger than its text) makes SwiftUI mark the window unable to use
/// full screen (`.fullScreenNone`), and such a window ignores `toggleFullScreen`, so it would
/// be stuck there.
struct FullScreenTracker: NSViewRepresentable {
    /// Whether the window is in full screen, or on its way in.
    @Binding var isFullScreen: Bool
    /// Whether full screen is wanted (the picture is showing); turning false leaves it.
    let wanted: Bool

    func makeNSView(context: Context) -> FullScreenNSView { FullScreenNSView() }

    func updateNSView(_ nsView: FullScreenNSView, context: Context) {
        nsView.changed = { isFullScreen = $0 }
        nsView.wanted = wanted
    }
}

/// `FullScreenTracker`'s view: draws nothing, watches its window.
final class FullScreenNSView: NSView {
    private static let logger = Logger(subsystem: "me.cbyrd.Glifftop", category: "window")

    var changed: (Bool) -> Void = { _ in }
    var wanted = false {
        didSet {
            if oldValue, !wanted { leaveIfUnwanted() }
        }
    }
    private var observers: [any NSObjectProtocol] = []
    /// Between will-enter and did-enter: AppKit ignores a toggle then, so leaving waits.
    private var entering = false

    isolated deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard let window else { return }
        observe(NSWindow.willEnterFullScreenNotification, of: window) { view in
            // On the way in counts as in: the content must stay free through the animation.
            view.entering = true
            view.changed(true)
            // A failed enter is told only to the window's delegate (SwiftUI's): look again.
            Task { [weak view] in
                try? await Task.sleep(for: .seconds(2))
                view?.settle()
            }
        }
        observe(NSWindow.didEnterFullScreenNotification, of: window) { $0.settle() }
        observe(NSWindow.didExitFullScreenNotification, of: window) { $0.settle() }
        // A restored window can open in full screen. Not inside SwiftUI's update pass.
        Task { self.settle() }
    }

    private func observe(
        _ name: Notification.Name, of window: NSWindow,
        _ action: @escaping @MainActor (FullScreenNSView) -> Void
    ) {
        observers.append(
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated {
                    if let self { action(self) }
                }
            })
    }

    /// Reports the window's own state, and leaves full screen if it isn't wanted: the picture
    /// may have gone while the window was on its way in.
    private func settle() {
        entering = false
        guard let window else { return }
        changed(window.styleMask.contains(.fullScreen))
        leaveIfUnwanted()
    }

    private func leaveIfUnwanted() {
        guard !wanted, !entering, let window, window.styleMask.contains(.fullScreen) else { return }
        // Not inside SwiftUI's update pass, which is taking the picture away.
        Task {
            guard !self.wanted, !self.entering, window.styleMask.contains(.fullScreen) else { return }
            window.toggleFullScreen(nil)
            // A window whose content can't grow ignores the toggle (`.fullScreenNone`).
            if window.styleMask.contains(.fullScreen) {
                Self.logger.error(
                    "couldn't leave full screen: behavior \(window.collectionBehavior.rawValue, privacy: .public)"
                )
            }
        }
    }
}
