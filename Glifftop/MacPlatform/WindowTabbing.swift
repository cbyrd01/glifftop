import AppKit
import SwiftUI
import os

/// The window's native tabs: once, joins the tab group of window `tabOf` (File ▸ New Tab), or
/// of the session window in front when no group is named (the tab bar's +), as a new tab
/// after its last; or leaves any group when opened `alone`. It reports the window's number and
/// its group's, in tab order, at each change (a tab added, closed, moved or torn off), and the
/// window's close. A group with a sheet up on any of its tabs takes no tab: the new window
/// stays on its own (File ▸ New Tab is disabled while the key window's own sheets show).
///
/// A SwiftUI window is already ordered in when its content reaches it, so `tabbingMode` can't
/// place it: the group is joined with `addTabbedWindow`, and a window opened alone that macOS
/// tabbed anyway (System Settings' "Prefer tabs: Always") leaves its group. The first window,
/// with none in front, stays where macOS put it.
struct WindowTabbing: NSViewRepresentable {
    static let identifier = "session"

    let tabOf: Int?
    let alone: Bool
    let changed: (_ group: (window: Int, tabs: [Int])) -> Void
    let closed: () -> Void

    func makeNSView(context: Context) -> TabbingView { TabbingView(tabOf: tabOf, alone: alone) }

    func updateNSView(_ view: TabbingView, context: Context) {
        (view.changed, view.closed) = (changed, closed)
    }

    /// File ▸ Close Window: every tab of the key window's group.
    static func closeKeyWindowGroup() {
        // A sheet's window is its parent's.
        guard let key = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        let window = key.sheetParent ?? key
        for tab in window.tabbedWindows ?? [window] { tab.performClose(nil) }
    }
}

final class TabbingView: NSView {
    private static let logger = Logger(subsystem: "me.cbyrd.Glifftop", category: "window")
    var changed: (_ group: (window: Int, tabs: [Int])) -> Void = { _ in }
    var closed: () -> Void = {}
    private let tabOf: Int?
    private let alone: Bool
    /// Whether the window has been placed: in the requested group, or alone.
    private var placed = false
    private var groupObservation: NSKeyValueObservation?
    /// The group `groupObservation` watches.
    private weak var observedGroup: NSWindowTabGroup?
    private var windowObservation: NSKeyValueObservation?
    private var closeObserver: (any NSObjectProtocol)?

    init(tabOf: Int?, alone: Bool) {
        (self.tabOf, self.alone) = (tabOf, alone)
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
        var joined: NSRect?
        if !placed {
            placed = true
            joined = place(window)
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
        // The group takes the size of the tab in front: the new tab, sized to the machines' form
        // until it knew it shares the window (reported just now). Back to the group's own,
        // after SwiftUI's update for that.
        if let joined { Task { window.setFrame(joined, display: true) } }
    }

    /// Joins the requested group, or the front session window's, returning the group's frame
    /// to keep (none in full screen, which keeps its own); a window opened alone stays alone.
    private func place(_ window: NSWindow) -> NSRect? {
        if alone {
            if let group = window.tabGroup, group.windows.count > 1 { group.removeWindow(window) }
            return nil
        }
        // Already in a group: macOS tabbed it ("Prefer tabs: Always").
        if let group = window.tabGroup, let other = group.windows.first(where: { $0 !== window }) {
            guard Self.showsSheet(group.windows) else { return Self.kept(other) }
            group.removeWindow(window)
            return nil
        }
        let source = tabOf.flatMap(NSApp.window(withWindowNumber:)) ?? NSApp.mainWindow
        guard let source, source !== window, source.tabbingIdentifier == WindowTabbing.identifier,
            !Self.showsSheet(source.tabbedWindows ?? [source])
        else { return nil }
        let frame = Self.kept(source)
        let last = source.tabbedWindows?.last { $0 !== window } ?? source
        last.addTabbedWindow(window, ordered: .above)
        window.makeKeyAndOrderFront(nil)
        return frame
    }

    /// A group with a sheet up takes no tab: AppKit lays the group out at the sheet's size. The
    /// new window stays on its own.
    private static func showsSheet(_ tabs: [NSWindow]) -> Bool {
        guard tabs.contains(where: { $0.attachedSheet != nil }) else { return false }
        logger.info("tab group shows a sheet: new window left alone")
        return true
    }

    private static func kept(_ tab: NSWindow) -> NSRect? {
        tab.styleMask.contains(.fullScreen) ? nil : tab.frame
    }

    /// Follows the window's current group, and reports it.
    private func observeGroup() {
        observedGroup = window?.tabGroup
        groupObservation = observedGroup?.observe(\.windows) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.report() }
        }
        report()
    }

    /// Reports the group, first following the window to a new one if it moved unannounced.
    private func report() {
        guard let window else { return }
        if window.tabGroup !== observedGroup { return observeGroup() }
        let tabs = window.tabGroup?.windows.map(\.windowNumber) ?? [window.windowNumber]
        changed((window.windowNumber, tabs))
    }
}
