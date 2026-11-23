/// Where a window's activation puts the remote pointer, in the remote's logical coordinates,
/// so the host's focus (which follows the pointer) lands on what the person sees.
public enum FocusTarget {
    /// The Mac pointer (already mapped by `PointerMapper`) when it is over the uncovered
    /// picture, else the remote cursor's last position (hidden or not: a cursor hidden while
    /// typing is still where the focus is), else the picture's centre.
    /// nil before there is a picture: nowhere to send the pointer.
    public static func target(
        macPointer: (x: Double, y: Double)?, cursor: (x: Double, y: Double)?,
        geometry: PictureGeometry
    ) -> (x: Double, y: Double)? {
        if let macPointer { return macPointer }
        if let cursor {
            return logical(bufferX: cursor.x, bufferY: cursor.y, geometry: geometry)
        }
        return logical(
            bufferX: Double(geometry.viewWidth) / 2, bufferY: Double(geometry.viewHeight) / 2,
            geometry: geometry)
    }

    /// Capture-buffer pixels (a CursorPos) to logical: `PointerMapper` over the view box
    /// itself, so stretched to the stream, clamped to it and divided by the remote scale. nil
    /// for a picture with no size.
    public static func logical(bufferX: Double, bufferY: Double, geometry: PictureGeometry) -> (
        x: Double, y: Double
    )? {
        let viewBox = PictureRect(
            x: 0, y: 0, width: Double(geometry.viewWidth), height: Double(geometry.viewHeight))
        return PointerMapper.remote(x: bufferX, y: bufferY, in: viewBox, geometry: geometry)
    }
}
