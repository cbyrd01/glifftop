import AppKit
import SwiftUI

/// The window's live resize (a drag of its edge), for the session: `changed(true)` as one
/// starts, `changed(false)` as it ends, or as the view leaves a window it was in one of.
struct LiveResizeTracker: NSViewRepresentable {
    let changed: (Bool) -> Void

    func makeNSView(context: Context) -> LiveResizeView {
        let view = LiveResizeView()
        view.changed = changed
        return view
    }

    func updateNSView(_ nsView: LiveResizeView, context: Context) { nsView.changed = changed }
}

/// `LiveResizeTracker`'s view: draws nothing, watches its window.
final class LiveResizeView: NSView {
    var changed: (Bool) -> Void = { _ in }
    private var observers: [any NSObjectProtocol] = []
    private var inLiveResizeReported = false

    isolated deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard let window else {
            report(false)
            return
        }
        observe(NSWindow.willStartLiveResizeNotification, of: window, on: true)
        observe(NSWindow.didEndLiveResizeNotification, of: window, on: false)
        report(window.inLiveResize)
    }

    private func observe(_ name: Notification.Name, of window: NSWindow, on: Bool) {
        observers.append(
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.report(on) }
            })
    }

    private func report(_ on: Bool) {
        guard on != inLiveResizeReported else { return }
        inLiveResizeReported = on
        changed(on)
    }
}
