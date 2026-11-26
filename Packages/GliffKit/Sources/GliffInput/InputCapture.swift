/// How a captured window treats the pointer and ⌘ chords ("Integrated" and "Capture"). Both
/// capture keys and the pointer on the same conditions.
public enum CaptureMode: String, Sendable, Equatable, CaseIterable, Codable {
    /// The pointer moves freely; over the chrome, ⌘ chords are the Mac's
    /// (`InputController.key(_:overChrome:)`).
    case integrated
    /// The pointer stays in the picture once it enters it, until capture ends or a suspension.
    case confined
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
    /// A click on the view takes input back after a release: an entry only if the last
    /// `.pointerOnPicture` has the pointer on the picture.
    case pictureClicked
    /// The Mac is going to sleep, or the screen locked: let go of everything held, without
    /// changing capture (the window stays key, so capture returns on its own). It frees a
    /// confined pointer.
    case away
    /// The app's menu tracking began (true) or ended (false): it holds capture off, and every
    /// key goes to the menu. One session, however many menus and submenus it opens.
    case menuOpen(Bool)
    /// The pointer entered the picture (true), or left it or was suspended (false). Only
    /// confinement reads it.
    case pointerOnPicture(Bool)
    case mode(CaptureMode)
}

/// What an applied `CaptureEvent` asks of the app.
public struct CaptureChange: Sendable, Equatable {
    /// Show the mode's hint now.
    public var showHint: Bool
    /// Capture rose: the window became key, the app active, the picture or the link came back,
    /// or a click took input back, so the host's focus should follow this window. A rise at a
    /// menu's or the Ports popover's close activates only when one of those happened while it
    /// was open; a mode change never moves capture; a quiet rise (`apply(_:quiet:)`: a window
    /// the app made key again itself) never activates, nor does an overlay's close after it.
    public var activates: Bool

    public init(showHint: Bool = false, activates: Bool = false) {
        self.showHint = showHint
        self.activates = activates
    }
}

/// Whether input is captured, and in Capture mode whether the pointer is confined, from the
/// `CaptureEvent`s so far; and when the hint shows: in Integrated on the first capture (or the
/// first switch to it while captured) of each picture and the first after each release, in
/// Capture on the first confinement of each. A new picture needs a new entry.
public struct InputCapture: Sendable {
    public private(set) var mode: CaptureMode
    public private(set) var isCaptured = false

    private var windowKey = false
    private var appActive = false
    private var picture = false
    private var interrupted = false
    private var menuOpen = false
    private var popover = false
    private var released = false
    /// The last `.pointerOnPicture`, or a recapturing click on the picture; each fall of
    /// capture, `.away`, a new picture and a change of mode make it false, so confinement needs a
    /// new entry. The app reports the pointer's place again after each of those, not only when
    /// its own last report changes.
    private var pointerOnPicture = false
    /// The last `.pointerOnPicture` as reported: where the pointer is, which nothing else
    /// changes. The app reports it for each click, just before the click.
    private var pointerOver = false
    /// Capture would have risen while an overlay held it off: its close is an activation.
    private var roseUnderOverlay = false
    /// The modes whose hint has shown for this picture since the last release; each mode's hint
    /// has its own moment.
    private var hintsShown: Set<CaptureMode> = []

    public init(mode: CaptureMode = .integrated) {
        self.mode = mode
    }

    /// Capture mode, captured, and the pointer has entered the picture since.
    public var isConfined: Bool { mode == .confined && isCaptured && pointerOnPicture }

    /// Shift+Esc released input, and no click on the picture or new picture took it back.
    public var isReleased: Bool { released }

    /// Whether a click on the picture would take input back: only Shift+Esc's release holds it
    /// off (not an interruption, a menu, the popover, focus or the picture's end).
    public var clickRecaptures: Bool { released && conditionsHold }

    /// The conditions for capture, Shift+Esc's release aside: the same in both modes.
    private var conditionsHold: Bool { conditionsBesideOverlay && !overlaid }

    /// An open menu or the Ports popover: each holds capture off while the window stays key.
    private var overlaid: Bool { menuOpen || popover }

    /// The window, the app, the picture and the link: the conditions an overlay doesn't touch.
    private var conditionsBesideOverlay: Bool { windowKey && appActive && picture && !interrupted }

    /// Captured but for an overlay.
    private var capturedBesideOverlay: Bool { conditionsBesideOverlay && !released }

    /// Whether Input ▸ Release Input has something to release: captured, or held off only by an
    /// overlay (any menu, the Input menu itself while the item is chosen, or the popover).
    public var isReleasable: Bool { capturedBesideOverlay }

    /// `quiet`: a rise that is no activation (a window made key again by the app itself, the
    /// host's focus never having left it).
    public mutating func apply(_ event: CaptureEvent, quiet: Bool = false) -> CaptureChange {
        let wasCaptured = isCaptured
        let wasBesideOverlay = capturedBesideOverlay
        switch event {
        case .windowKey(let key): windowKey = key
        case .appActive(let active): appActive = active
        case .picture(let shown):
            // A new picture (a new session) starts captured again, with the hint, and needs a
            // new entry.
            if shown, !picture {
                released = false
                hintsShown.removeAll()
                pointerOnPicture = false
            }
            picture = shown
        case .interrupted(let on): interrupted = on
        case .popover(let on):
            if on, !overlaid { roseUnderOverlay = false }
            popover = on
        case .release:
            released = true
            hintsShown.removeAll()
        // Only when nothing else holds capture off (`clickRecaptures`).
        // A click on the picture is an entry; one beside it (the bars of a wider window) isn't.
        case .pictureClicked:
            if conditionsHold {
                released = false
                pointerOnPicture = pointerOver
            }
        case .away: pointerOnPicture = false
        case .menuOpen(let open):
            // A new menu session, not a submenu's report within one.
            if open, !overlaid { roseUnderOverlay = false }
            menuOpen = open
        case .pointerOnPicture(let on):
            pointerOnPicture = on
            pointerOver = on
        case .mode(let new):
            if new != mode { pointerOnPicture = false }
            mode = new
        }
        isCaptured = conditionsHold && !released
        if wasCaptured, !isCaptured { pointerOnPicture = false }
        if overlaid, capturedBesideOverlay, !wasBesideOverlay, !quiet { roseUnderOverlay = true }
        let rose = isCaptured && !wasCaptured
        // An overlay closing alone is no activation: the window stayed key, and the host's
        // focus with it.
        let overlayClosing =
            switch event {
            case .menuOpen(false), .popover(false): true
            default: false
            }
        // The mode's state, the first time it holds since the last release or new picture
        // (a switch to Integrated while captured included).
        let hintState = mode == .confined ? isConfined : isCaptured
        return CaptureChange(
            showHint: hintState && hintsShown.insert(mode).inserted,
            activates: rose && !quiet && (!overlayClosing || roseUnderOverlay))
    }
}
