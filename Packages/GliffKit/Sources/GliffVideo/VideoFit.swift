/// A size in pixels.
public struct PixelSize: Equatable, Sendable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

/// Where a picture goes in a drawable, in the drawable's pixels.
public struct VideoViewport: Equatable, Sendable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int
    /// The picture is shown 1:1, pixel for pixel.
    public var isActualSize: Bool

    public init(x: Int, y: Int, width: Int, height: Int, isActualSize: Bool) {
        (self.x, self.y, self.width, self.height, self.isActualSize) = (x, y, width, height, isActualSize)
    }
}

/// How the remote picture fits the window: scaled down only when it must be, and scaled up
/// only with Scale to Fit.
public enum VideoFit {
    /// How far short of filling the drawable a picture may be and still count as filling it
    /// for Scale to Fit, in pixels: the server's rounding (Hyprland's `clean_mode` steps up to
    /// 14 at the text sizes offered, `fit_mirror` 2) leaves a border that stays 1:1.
    public static let nearFit = 16

    /// The picture 1:1 and centred when it fits the drawable (with `scaleToFit`, when it also
    /// comes within `nearFit` of filling it); otherwise scaled with its aspect kept, centred:
    /// the limiting side fills the drawable exactly, the other is floored, and so are the
    /// origins. A picture with no area is left as it is, and isn't actual size.
    public static func viewport(picture: PixelSize, drawable: PixelSize, scaleToFit: Bool)
        -> VideoViewport
    {
        let fits = picture.width <= drawable.width && picture.height <= drawable.height
        let hasArea = picture.width > 0 && picture.height > 0
        var (width, height) = (picture.width, picture.height)
        if hasArea, !fits || scaleToFit {
            // Integers, so no rounding leaves the limiting side a pixel short.
            if drawable.width * picture.height <= drawable.height * picture.width {
                (width, height) = (drawable.width, picture.height * drawable.width / picture.width)
            } else {
                (width, height) = (picture.width * drawable.height / picture.height, drawable.height)
            }
            if fits, width - picture.width <= nearFit, height - picture.height <= nearFit {
                (width, height) = (picture.width, picture.height)
            }
        }
        return VideoViewport(
            x: (drawable.width - width) / 2, y: (drawable.height - height) / 2, width: width, height: height,
            isActualSize: hasArea && fits && width == picture.width && height == picture.height)
    }

    /// The window content size, in points, for a `view`-pixel picture on a `backingScale`
    /// display: actual size when that fits `available`, else the largest size that fits with
    /// the same aspect, floored to whole backing pixels. A scale of 0 or less (a window not yet on a screen) counts as 1.
    public static func contentSize(
        view: PixelSize, backingScale: Double, available: (width: Double, height: Double)
    )
        -> (width: Double, height: Double, isActualSize: Bool)
    {
        let scale = backingScale > 0 ? backingScale : 1
        let width = Double(view.width) / scale
        let height = Double(view.height) / scale
        guard width > available.width || height > available.height else { return (width, height, true) }
        // In whole backing pixels, with viewport's integer maths: the limiting side fills the
        // available space exactly, so the drawable isn't a pixel short.
        let fit = viewport(
            picture: view,
            drawable: PixelSize(
                width: Int((available.width * scale).rounded(.down)),
                height: Int((available.height * scale).rounded(.down))),
            scaleToFit: false)
        return (Double(fit.width) / scale, Double(fit.height) / scale, false)
    }
}
