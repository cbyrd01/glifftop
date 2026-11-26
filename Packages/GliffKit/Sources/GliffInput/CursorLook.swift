public import GliffProtocol

/// What the pointer looks like over the picture. While input is captured: the remote's
/// visible shape, sized so a remote pixel matches a picture pixel on screen. With no shape to
/// show (none yet, one that can't be shown or has nothing to show, no picture to size it by):
/// a hidden cursor when the video carries the pointer (`videoHasPointer`), otherwise the Mac
/// arrow (upstream `set_remote_cursor`). Confined: the Mac cursor hidden, as it stays put; the
/// app draws the virtual pointer with the captured look. Released: the arrow.
public enum CursorLook: Sendable, Equatable {
    case arrow
    case hidden
    case shape(CursorImage, pointsPerPixel: Double)

    public static func choose(
        captured: Bool, videoHasPointer: Bool, image: CursorImage?, pointsPerPixel: Double?,
        confined: Bool = false
    )
        -> CursorLook
    {
        guard captured else { return .arrow }
        if confined { return .hidden }
        guard let image, image.isVisible, let pointsPerPixel else {
            return videoHasPointer ? .hidden : .arrow
        }
        return .shape(image, pointsPerPixel: pointsPerPixel)
    }

    /// Whether the session's video carries the host's pointer: a virtual screen's, this
    /// session's (`headless`) or another's mirrored (`gliff-<pid>`), or a monitor of Hyprland's
    /// headless backend named `HEADLESS-N`, such as a container's. Their cursor is drawn into
    /// the picture. A real monitor's isn't, nor is a session's not yet started. A headless
    /// output given another name (`hyprctl output create headless NAME`) isn't recognised.
    public static func videoHasPointer(_ session: SessionInfo?) -> Bool {
        guard let session else { return false }
        return session.headless || session.output.hasPrefix("HEADLESS-")
            || OutputName.isVirtualScreen(session.output)
    }
}
