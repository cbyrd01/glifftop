/// A motion soon after confinement's warp of the Mac pointer to the view's centre: when its
/// delta carries the warp's displacement (within a quarter of the warp's length, or 1 point, of
/// it), the warp is taken out and the hand's own motion is left.
public enum StartWarp {
    /// The hand's motion in `delta` (points), the warp being `warp` (points, the same axes);
    /// nil when `delta` doesn't carry the warp (it is the hand's alone).
    public static func handMotion(
        delta: (dx: Double, dy: Double), warp: (dx: Double, dy: Double)
    ) -> (dx: Double, dy: Double)? {
        let rest = (dx: delta.dx - warp.dx, dy: delta.dy - warp.dy)
        let restSquared = rest.dx * rest.dx + rest.dy * rest.dy
        let tolerance = max(1, (warp.dx * warp.dx + warp.dy * warp.dy) / 16)
        return restSquared <= tolerance ? rest : nil
    }
}
