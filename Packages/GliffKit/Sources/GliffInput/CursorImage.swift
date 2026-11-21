public import GliffProtocol

/// A remote cursor shape the app can show: checked as upstream's `remote_cursor` does, but
/// strictly: each side 1…1024, its payload exactly `width × height × 4` bytes, the
/// hotspot inside. The bytes are B, G, R, A (`wl_shm` ARGB8888, little-endian), premultiplied.
/// A valid shape with nothing to show (every pixel clear, or every pixel the same) is kept, but
/// not visible (upstream `has_visible_shape`). A shape that can't be shown, or isn't visible,
/// gets the Mac arrow, or no cursor on a headless session, whose video carries the pointer
/// (upstream `set_remote_cursor`).
public struct CursorImage: Sendable, Equatable {
    public let id, width, height: UInt32
    public let hotX, hotY: Int32
    public let bgra: [UInt8]
    public let isVisible: Bool

    /// Nil when the shape can't be shown as sent.
    public init?(_ shape: CursorShape, payload: [UInt8]) {
        guard shape.payloadFits, payload.count == Int(shape.argbLength),
            (0..<Int64(shape.width)).contains(Int64(shape.hotX)),
            (0..<Int64(shape.height)).contains(Int64(shape.hotY))
        else { return nil }
        (id, width, height) = (shape.id, shape.width, shape.height)
        (hotX, hotY) = (shape.hotX, shape.hotY)
        bgra = payload
        let first = payload.prefix(4)
        isVisible =
            stride(from: 3, to: payload.count, by: 4).contains { payload[$0] != 0 }
            && stride(from: 4, to: payload.count, by: 4).contains {
                !payload[$0..<$0 + 4].elementsEqual(first)
            }
    }

    /// The cursor's pixels are remote view pixels, so on screen each takes the picture's scale:
    /// the picture's drawn width (`rectWidth`, backing pixels) per view pixel, in points. Nil
    /// without a size to go on (no picture yet, a window with no screen).
    public static func pointsPerPixel(rectWidth: Double, viewWidth: Int, backingScale: Double) -> Double? {
        let points = rectWidth / Double(viewWidth) / backingScale
        guard rectWidth > 0, viewWidth > 0, backingScale > 0, points.isFinite else { return nil }
        return points
    }
}
