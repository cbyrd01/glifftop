import AppKit

/// Watches the pointer over the picture of a window that isn't key, for the handover between a
/// host's monitor windows: the owner of a second tracking area on its video view, over whatever
/// part of it is visible, active while the app is, which reports each motion and the exit to
/// `MonitorHandoverCoordinator`. The view's own tracking area acts only in the key window.
final class PictureHoverWatcher: NSResponder {
    private(set) weak var view: VideoNSView?
    private var area: NSTrackingArea?
    private let moved: (NSEvent) -> Void
    private let exited: () -> Void

    /// Starts watching `view` at once; `remove()` stops.
    init(view: VideoNSView, moved: @escaping (NSEvent) -> Void, exited: @escaping () -> Void) {
        self.view = view
        self.moved = moved
        self.exited = exited
        super.init()
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self)
        view.addTrackingArea(area)
        self.area = area
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("PictureHoverWatcher is made in code") }

    func remove() {
        if let area { view?.removeTrackingArea(area) }
        area = nil
    }

    // Coming in starts nothing (NSResponder passes it on, to no one): only a motion does.
    override func mouseMoved(with event: NSEvent) { moved(event) }
    override func mouseExited(with event: NSEvent) { exited() }
}
