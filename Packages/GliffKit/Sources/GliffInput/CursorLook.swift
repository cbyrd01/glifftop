/// What the pointer looks like over the picture. While input is captured: the remote's
/// visible shape, sized so a remote pixel matches a picture pixel on screen. With no shape to
/// show (none yet, one that can't be shown or has nothing to show, no picture to size it by):
/// on a headless session, whose video carries the pointer, a hidden cursor; otherwise the Mac
/// arrow (upstream `set_remote_cursor`). Released: the arrow.
public enum CursorLook: Sendable, Equatable {
    case arrow
    case hidden
    case shape(CursorImage, pointsPerPixel: Double)

    public static func choose(captured: Bool, headless: Bool, image: CursorImage?, pointsPerPixel: Double?)
        -> CursorLook
    {
        guard captured else { return .arrow }
        guard let image, image.isVisible, let pointsPerPixel else { return headless ? .hidden : .arrow }
        return .shape(image, pointsPerPixel: pointsPerPixel)
    }
}
