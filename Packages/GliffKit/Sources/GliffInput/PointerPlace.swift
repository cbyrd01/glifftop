/// Where a ⌘ key event happened, for Integrated's routing: on the picture, over Glifftop's own
/// chrome (where ⌘ chords are the Mac's), or outside. The app's probe gathers the `Facts`; the
/// rule is here.
public enum PointerPlace: Sendable, Equatable {
    case picture, chrome, outside

    /// What the app's probe found at the event's location.
    public struct Facts: Sendable, Equatable {
        /// The window under the point, as it relates to the key session window.
        public enum Window: Sendable, Equatable {
            /// The key session window: `inVideoView` when the point is in its video view's frame
            /// on screen. The frame decides, not a hit test: an overlay on the picture (the hint,
            /// a notice) counts as the picture.
            case keySession(inVideoView: Bool)
            /// A window whose parent chain reaches the key session window (a popover).
            case attachedToKeySession
            /// Another window of Glifftop's (another session, Settings).
            case otherOfOurs
            /// Not Glifftop's (another app, the desktop, the menu bar's own window).
            case notOurs
        }

        /// A drag that began on the picture is under way.
        public var dragFromPicture: Bool
        public var window: Window
        /// The point lies in the menu bar's height at the top of its screen. It counts only
        /// outside the key session window: a shown or revealed menu bar has its own window
        /// there (not ours), so the key session window under the strip means no menu bar.
        public var inMenuBarStrip: Bool

        public init(dragFromPicture: Bool = false, window: Window, inMenuBarStrip: Bool = false) {
            self.dragFromPicture = dragFromPicture
            self.window = window
            self.inMenuBarStrip = inMenuBarStrip
        }
    }

    /// A drag from the picture is the picture; the key session window is the picture inside its
    /// video view and the chrome elsewhere; a window attached to it is the chrome; any other
    /// window in the menu-bar strip is the chrome (the menu bar); everything else is outside.
    public static func classify(_ facts: Facts) -> PointerPlace {
        if facts.dragFromPicture { return .picture }
        switch facts.window {
        case .keySession(let inVideoView): return inVideoView ? .picture : .chrome
        case .attachedToKeySession: return .chrome
        case .otherOfOurs, .notOurs: return facts.inMenuBarStrip ? .chrome : .outside
        }
    }
}
