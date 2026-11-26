/// When keys and the pointer go to the remote (one capture for both). Mode A is the only
/// mode; capture-and-release and "integrated" modes would join `CaptureMode`, with their own
/// rules here.
public enum CaptureMode: Sendable {
    /// While the window is in front and showing the live picture.
    case windowInFront
}

/// What capture depends on. The app reports each change. `picture` is false only once the
/// session's picture has gone for good (its end): a resize or a new stream size keeps it.
public enum CaptureEvent: Sendable, Equatable {
    case windowKey(Bool)
    case appActive(Bool)
    case picture(Bool)
    case interrupted(Bool)
    /// A popover with fields (Ports) is over the window: its keys are the Mac's while it is.
    case popover(Bool)
    /// Shift+Esc, or Input ▸ Release Input: keys and pointer go back to the Mac.
    case release
    /// A click on the picture takes input back after a release.
    case pictureClicked
    /// The Mac is going to sleep, or the screen locked: let go of everything held, without
    /// changing capture (the window stays key, so capture returns on its own).
    case away
}

/// Whether input is captured, from the `CaptureEvent`s so far, and when the
/// "Shift+Esc releases input" hint shows: on the first capture of each picture and the
/// first after each release, not on every focus change.
public struct InputCapture: Sendable {
    public let mode: CaptureMode
    public private(set) var isCaptured = false

    private var windowKey = false
    private var appActive = false
    private var picture = false
    private var interrupted = false
    private var popover = false
    private var released = false
    private var hintDue = true

    public init(mode: CaptureMode) {
        self.mode = mode
    }

    /// Whether a click on the picture would take input back: only Shift+Esc's release holds it
    /// off (not an interruption, focus or the picture's end).
    public var clickRecaptures: Bool { released && conditionsHold }

    /// The mode's conditions for capture, Shift+Esc's release aside.
    private var conditionsHold: Bool {
        switch mode {
        case .windowInFront: windowKey && appActive && picture && !interrupted && !popover
        }
    }

    /// Applies `event`. Returns whether to show the hint now.
    public mutating func apply(_ event: CaptureEvent) -> Bool {
        switch event {
        case .windowKey(let key): windowKey = key
        case .appActive(let active): appActive = active
        case .picture(let shown):
            // A new picture (a new session) starts captured again, with the hint.
            if shown, !picture {
                released = false
                hintDue = true
            }
            picture = shown
        case .interrupted(let on): interrupted = on
        case .popover(let on): popover = on
        case .release:
            released = true
            hintDue = true
        // Only when nothing else holds capture off (`clickRecaptures`).
        case .pictureClicked: if conditionsHold { released = false }
        case .away: break
        }
        let wasCaptured = isCaptured
        isCaptured = conditionsHold && !released
        guard isCaptured, !wasCaptured, hintDue else { return false }
        hintDue = false
        return true
    }
}
