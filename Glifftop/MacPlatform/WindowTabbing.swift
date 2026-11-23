import AppKit
import SwiftUI

/// The window's native tabs: joins the tab group of window `tabOf` once (a new tab, added after
/// its last tab), and reports the window's number and its group's, in tab order, at each change
/// (a tab added, closed, moved or torn off), and the window's close.
///
/// A SwiftUI window is already ordered in when its content reaches it, so `tabbingMode` can't
/// place it: the group is joined with `addTabbedWindow`, and a window opened alone that macOS
/// tabbed anyway (System Settings' "Prefer tabs: Always") leaves its group.
struct WindowTabbing: NSViewRepresentable {
    static let identifier = "session"

    let tabOf: Int?
    let changed: (_ group: (window: Int, tabs: [Int])) -> Void
    let closed: () -> Void

    func makeNSView(context: Context) -> TabbingView { TabbingView(tabOf: tabOf) }

    func updateNSView(_ view: TabbingView, context: Context) {
        (view.changed, view.closed) = (changed, closed)
    }

    /// File ▸ Close Window: every tab of the key window's group.
    static func closeKeyWindowGroup() {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        for tab in window.tabbedWindows ?? [window] { tab.performClose(nil) }
    }
}

final class TabbingView: NSView {
    var changed: (_ group: (window: Int, tabs: [Int])) -> Void = { _ in }
    var closed: () -> Void = {}
    private let tabOf: Int?
    /// Whether the window has been placed: in the requested group, or alone.
    private var placed = false
    private var groupObservation: NSKeyValueObservation?
    private var windowObservation: NSKeyValueObservation?
    private var closeObserver: (any NSObjectProtocol)?

    init(tabOf: Int?) {
        self.tabOf = tabOf
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    isolated deinit {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        window.tabbingIdentifier = WindowTabbing.identifier
        window.tabbingMode = .preferred
        if !placed {
            placed = true
            place(window)
        }
        windowObservation = window.observe(\.tabGroup) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.observeGroup() }
        }
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.closed() }
        }
        observeGroup()
    }

    /// Joins the requested group; a window opened alone stays alone.
    private func place(_ window: NSWindow) {
        guard let tabOf else {
            if let group = window.tabGroup, group.windows.count > 1 { group.removeWindow(window) }
            return
        }
        // Already in its group: macOS tabbed it ("Prefer tabs: Always").
        guard let source = NSApp.window(withWindowNumber: tabOf), source !== window,
            window.tabGroup == nil || window.tabGroup !== source.tabGroup
        else { return }
        let last = source.tabbedWindows?.last { $0 !== window } ?? source
        last.addTabbedWindow(window, ordered: .above)
        window.makeKeyAndOrderFront(nil)
    }

    /// Follows the window's current group, and reports it.
    private func observeGroup() {
        groupObservation = window?.tabGroup?.observe(\.windows) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.report() }
        }
        report()
    }

    private func report() {
        guard let window else { return }
        let tabs = window.tabGroup?.windows.map(\.windowNumber) ?? [window.windowNumber]
        changed((window.windowNumber, tabs))
    }
}
