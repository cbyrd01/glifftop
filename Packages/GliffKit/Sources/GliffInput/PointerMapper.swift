/// Where a picture is drawn, in backing pixels from the drawable's top-left.
public struct PictureRect: Sendable, Equatable {
    public var x, y, width, height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        (self.x, self.y, self.width, self.height) = (x, y, width, height)
    }
}

/// What a picture shows: the coded stream's size, the remote view box it fills, and the
/// remote output's scale (`scale_milli`: 1000 is 1×).
public struct PictureGeometry: Sendable, Equatable {
    public var streamWidth, streamHeight, viewWidth, viewHeight: Int
    public var scaleMilli: UInt32

    public init(streamWidth: Int, streamHeight: Int, viewWidth: Int, viewHeight: Int, scaleMilli: UInt32) {
        (self.streamWidth, self.streamHeight) = (streamWidth, streamHeight)
        (self.viewWidth, self.viewHeight, self.scaleMilli) = (viewWidth, viewHeight, scaleMilli)
    }
}

/// A point over the drawn picture to the remote's logical coordinates, as upstream's
/// `to_remote`: undo the fit to view-box pixels, stretch the view box to the stream, clamp to
/// the stream (a point in the letterbox bars reaches the nearest edge), then divide by the
/// remote scale, which is what the remote's virtual pointer expects.
public enum PointerMapper {
    /// nil when the rect or the picture has no size, or the point isn't finite (the clamp
    /// would let NaN through to the wire). The scale is divided in Double, not upstream's f32:
    /// a difference of well under a thousandth of a pixel.
    public static func remote(x: Double, y: Double, in rect: PictureRect, geometry: PictureGeometry)
        -> (x: Double, y: Double)?
    {
        let (streamWidth, streamHeight) = (Double(geometry.streamWidth), Double(geometry.streamHeight))
        let (viewWidth, viewHeight) = (Double(geometry.viewWidth), Double(geometry.viewHeight))
        guard x.isFinite, y.isFinite, rect.width > 0, rect.height > 0, streamWidth > 0, streamHeight > 0,
            viewWidth > 0,
            viewHeight > 0
        else { return nil }
        let viewX = (x - rect.x) * viewWidth / rect.width
        let viewY = (y - rect.y) * viewHeight / rect.height
        let streamX = min(max(viewX * streamWidth / viewWidth, 0), streamWidth)
        let streamY = min(max(viewY * streamHeight / viewHeight, 0), streamHeight)
        let scale = max(Double(geometry.scaleMilli) / 1000, 0.01)
        return (streamX / scale, streamY / scale)
    }
}
