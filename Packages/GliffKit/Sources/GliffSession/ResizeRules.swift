import GliffProtocol

/// What the window wants the remote screen to be: its drawable size in pixels, the
/// display's backing scale, and the text size chosen for a virtual screen (1 is the Mac's).
public struct ViewTarget: Equatable, Sendable {
    public var width: UInt32
    public var height: UInt32
    public var backingScale: Double
    public var textFactor: Double

    public init(width: UInt32, height: UInt32, backingScale: Double, textFactor: Double) {
        (self.width, self.height, self.backingScale, self.textFactor) = (
            width, height, backingScale, textFactor
        )
    }

    /// A virtual screen's scale on a display of `backingScale` at `textFactor`: their product,
    /// never below 1 nor above the server's 4. What a Resize asks for, and what a menu offering
    /// text sizes should show.
    public static func virtualScale(backingScale: Double, textFactor: Double) -> Double {
        min(max(backingScale * textFactor, 1), 4)
    }
}

/// When a `ViewTarget` goes to the server as a Resize (upstream `request_resize`, plus a
/// settle delay so a live drag sends once it pauses):
/// - nothing smaller than the server takes (320×240);
/// - a virtual screen's scale is the backing scale times the text factor, 1–4 (never below
///   the Mac's 1×); a mirror's is the backing scale, 0.5–4 (the server ignores it there);
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

    mutating func set(_ target: ViewTarget, now: UInt64) {
        guard target != self.target else { return }
        self.target = target
        changedAt = now
    }

    /// The Resize to send now, if any; it is then recorded as sent.
    mutating func due(now: UInt64, headless: Bool, view: View) -> ClientMessage? {
        // A clock step backwards counts as settled rather than waiting it out.
        guard let target, now < changedAt || now - changedAt >= Self.settle,
            target.width >= Self.minimum.width, target.height >= Self.minimum.height,
            // Never equal to what was sent, so it would go every tick.
            target.backingScale.isFinite, target.textFactor.isFinite
        else { return nil }
        let scale =
            headless
            ? ViewTarget.virtualScale(backingScale: target.backingScale, textFactor: target.textFactor)
            : min(max(target.backingScale, 0.5), 4)
        let request = View(width: target.width, height: target.height, scale: Float(scale))
        guard request != lastSent else { return nil }
        if view.width == request.width, view.height == request.height,
            !headless || abs(view.scale - request.scale) < 0.005
        {
            return nil
        }
        lastSent = request
        return .resize(width: request.width, height: request.height, scale: request.scale)
    }
}
