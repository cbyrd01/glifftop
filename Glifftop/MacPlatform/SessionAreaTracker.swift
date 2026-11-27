import AppKit
import GliffVideo
import SwiftUI
import os

/// A virtual screen's window before its picture: fills the screen once (`fills`), then
/// reports the size the picture will have (this area less `extraHeight` points, the status
/// bar) and the backing scale, as the video view will, so the remote screen is asked for that
/// size while the session connects and the video view's report adds nothing. The video view's
/// first fit fills the window again, which changes nothing once this filled it, and covers a
/// window this couldn't fill (full screen, or a tab).
struct SessionAreaTracker: NSViewRepresentable {
    /// Whether the window is sized for the session (a first window, not a tab or a reconnect).
    let fills: Bool
    let extraHeight: CGFloat
    let onTarget: (PixelSize, Double) -> Void

    func makeNSView(context: Context) -> SessionAreaView { SessionAreaView(fills: fills) }

    func updateNSView(_ nsView: SessionAreaView, context: Context) {
        nsView.onTarget = onTarget
        nsView.extraHeight = extraHeight
    }
}

/// `SessionAreaTracker`'s view: draws nothing, measures itself.
final class SessionAreaView: NSView {
    private static let logger = Logger(subsystem: "io.github.cbyrd01.Glifftop", category: "window")

    var onTarget: (PixelSize, Double) -> Void = { _, _ in }
    var extraHeight: CGFloat = 0 {
        didSet {
            if extraHeight != oldValue { report() }
        }
    }
    private let fills: Bool
    /// The window has its size for the session: no report before, as the first goes at once.
    private var ready = false
    /// The fill is queued: it runs once.
    private var filling = false
    /// A measure is queued: reports in one turn make one.
    private var measuring = false
    private var reported: (size: PixelSize, backingScale: Double)?

    init(fills: Bool) {
        self.fills = fills
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !ready, !filling else { return }
        filling = true
        // Not inside SwiftUI's update pass: resizing the window there re-enters its layout.
        Task {
            filling = false
            // Removed, or moved to another window, meanwhile: a later move fills that one.
            guard let window = self.window else { return }
            if fills { WindowSizer.fill(window) }
            window.layoutIfNeeded()
            ready = true
            report()
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        report()
    }

    /// The size a live resize ended on, laid out and reported now, ahead of its end
    /// (`LiveResizeTracker`).
    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        guard ready else { return }
        window?.layoutIfNeeded()
        measure()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        report()
    }

    /// Measures on a later turn: after SwiftUI's layout, and outside its update pass, as the
    /// target changes observed state.
    private func report() {
        guard ready, !measuring else { return }
        measuring = true
        Task {
            measuring = false
            measure()
        }
    }

    private func measure() {
        guard let window else { return }
        let size = backingPixels(minusHeight: extraHeight)
        guard size.width > 0, size.height > 0 else { return }
        let target = (size: size, backingScale: Double(window.backingScaleFactor))
        if let reported, reported == target { return }
        reported = target
        Self.logger.debug("session area \(size.width)×\(size.height) at \(target.backingScale)")
        onTarget(target.size, target.backingScale)
    }
}
