import GliffInput
import GliffVideo

extension Picture {
    /// What `PointerMapper` maps over: the stream's size, and its view box and scale read
    /// together, from one StreamConfig.
    var pointerGeometry: PictureGeometry {
        let (view, scaleMilli) = geometry
        return PictureGeometry(
            streamWidth: width, streamHeight: height, viewWidth: view.width, viewHeight: view.height,
            scaleMilli: scaleMilli)
    }
}
