import AppKit
import QuartzCore

/// The display link's target: it holds its view weakly, so a link that outlives the view (a
/// window closed without detaching it) keeps nothing alive and stops itself.
final class VideoDisplayLinkTarget: NSObject {
    private weak var view: VideoNSView?

    init(_ view: VideoNSView) {
        self.view = view
    }

    @objc func step(_ link: CADisplayLink) {
        guard let view else {
            link.invalidate()
            return
        }
        view.step()
    }
}
