import GliffProtocol

/// What the window wants the remote screen to be: its drawable size in pixels, the
/// display's backing scale, and, for a virtual screen, the text size chosen (1 is the Mac's)
/// and the resolution.
public struct ViewTarget: Equatable, Sendable {
    public var width: UInt32
    public var height: UInt32
    public var backingScale: Double
    public var textFactor: Double
    public var resolution: VirtualResolution

    public init(
        width: UInt32, height: UInt32, backingScale: Double, textFactor: Double,
        resolution: VirtualResolution = .retina
    ) {
        (self.width, self.height, self.backingScale, self.textFactor, self.resolution) = (
            width, height, backingScale, textFactor, resolution
        )
    }

    /// A virtual screen's scale on a display of `backingScale` at `textFactor`: their product,
    /// never below 1 nor above the server's 4. What a Resize asks for, and what a menu offering
    /// text sizes should show.
    public static func virtualScale(backingScale: Double, textFactor: Double) -> Double {
        min(max(backingScale * textFactor, 1), 4)
    }

    /// Whether a virtual screen's picture of `screenScale` is Standard's (r = ½): under ¾ of
    /// the scale the window asks at Retina. The picture in hand decides, not the choice: after
    /// a change, the old picture shows until the server answers.
    public static func isStandardPicture(screenScale: Double, backingScale: Double, textFactor: Double)
        -> Bool
    {
        screenScale < virtualScale(backingScale: backingScale, textFactor: textFactor) * 0.75
    }
}

/// When a `ViewTarget` goes to the server as a Resize (upstream `request_resize`):
/// - the session's first target it can send at once (the server's screen starts at its own
///   default);
/// - none during a live resize, and the size it ended on at once;
/// - any other once it has stayed unchanged for `settle` (full screen, zoom, a pause in a
///   drag the window doesn't report);
/// - nothing smaller than the server takes (320×240);
/// - a virtual screen's scale is the backing scale times the text factor, 1–4 (never below
///   the Mac's 1×); a mirror's is the backing scale, 0.5–4 (the server ignores it there);
/// - a virtual screen's size and scale are then multiplied by its resolution's factor
///   (`VirtualResolution`, ½ for Standard), which keeps its layout and may take the scale
///   below 1 (to 0.5);
/// - never the request last sent, nor the server's view at that scale: the server's rounded
///   answer (`clean_mode`, `fit_mirror`) sends nothing more. (A virtual screen larger than
///   the encoder's limit streams a smaller view: one Resize per target then goes, which the
///   server finds unchanged and ignores.)
/// - a target whose scale isn't a finite number is never sent.
struct ResizeRules {
    /// The server's view now: its size and, for a virtual screen, its scale.
    struct View: Equatable {
        var width, height: UInt32
        var scale: Float
    }

    /// How long a target must stay unchanged before it is sent, in ms.
    static let settle: UInt64 = 200
    static let minimum = (width: UInt32(320), height: UInt32(240))

    private var target: ViewTarget?
    private var changedAt: UInt64 = 0
    private var lastSent: View?
    /// A target has been weighed: the next ones wait for the settle.
    private var weighed = false
    private var liveResize = false
    /// The target in hand is the one a live resize ended on: it goes without the settle.
    private var endedDrag = false

    mutating func set(_ target: ViewTarget, now: UInt64) {
        guard target != self.target else { return }
        self.target = target
        changedAt = now
        endedDrag = false
    }

    /// The window's live resize (a drag of its edge) starts or ends.
    mutating func setLiveResize(_ on: Bool) {
        guard on != liveResize else { return }
        liveResize = on
        if !on { endedDrag = true }
    }

    /// The Resize to send now, if any; it is then recorded as sent.
    /// `pipeline` is the stream's, for Automatic resolution (nil before it's known).
    mutating func due(now: UInt64, headless: Bool, view: View, pipeline: VideoPipeline?) -> ClientMessage? {
        // A clock step backwards counts as settled rather than waiting it out.
        guard !liveResize, let target,
            !weighed || endedDrag || now < changedAt || now - changedAt >= Self.settle,
            let request = Self.request(for: target, headless: headless, pipeline: pipeline)
        else { return nil }
        (weighed, endedDrag) = (true, false)
        guard request != lastSent, !Self.shows(request, view: view, headless: headless) else { return nil }
        lastSent = request
        return .resize(width: request.width, height: request.height, scale: request.scale)
    }

    /// Whether a target is in hand and leaves nothing to ask for: the server's view is what it
    /// asks, or it can't be sent.
    func isSatisfied(headless: Bool, view: View, pipeline: VideoPipeline?) -> Bool {
        guard let target else { return false }
        guard let request = Self.request(for: target, headless: headless, pipeline: pipeline) else {
            return true
        }
        return Self.shows(request, view: view, headless: headless)
    }

    /// What `target` asks the server for; nil for one too small, or whose scale isn't a
    /// finite number (it would never equal what was sent, so it would go every tick).
    private static func request(for target: ViewTarget, headless: Bool, pipeline: VideoPipeline?) -> View? {
        guard target.width >= minimum.width, target.height >= minimum.height,
            target.backingScale.isFinite, target.textFactor.isFinite
        else { return nil }
        guard headless else {
            return View(
                width: target.width, height: target.height,
                scale: Float(min(max(target.backingScale, 0.5), 4)))
        }
        let r = target.resolution.factor(
            pipeline: pipeline, backingScale: target.backingScale, width: target.width, height: target.height)
        let scale = ViewTarget.virtualScale(backingScale: target.backingScale, textFactor: target.textFactor)
        return View(
            width: UInt32(Double(target.width) * r), height: UInt32(Double(target.height) * r),
            scale: Float(scale * r))
    }

    /// Whether `view` is `request`: a mirror's scale isn't the server's to change.
    private static func shows(_ request: View, view: View, headless: Bool) -> Bool {
        view.width == request.width && view.height == request.height
            && (!headless || abs(view.scale - request.scale) < 0.005)
    }
}
