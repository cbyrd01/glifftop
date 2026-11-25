/// How a captured window treats the pointer and ⌘ chords ("Integrated" and "Capture"). Both
/// capture keys and the pointer on the same conditions.
public enum CaptureMode: Sendable, Equatable, CaseIterable {
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
    /// Shift+Esc, or Input ▸ Release Input: keys and pointer go back to the Mac.
    case release
    /// A click on the picture takes input back after a release.
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
    /// menu's close activates only when one of those happened while the menu was open; a mode
    /// change never moves capture.
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
    private var released = false
    /// The last `.pointerOnPicture`, or a recapturing click; each fall of capture, `.away`, a
    /// new picture and a change of mode make it false, so confinement needs a new entry. The
    /// app reports the pointer's
    /// place again after each of those, not only when its own last report changes.
    private var pointerOnPicture = false
    /// Capture would have risen while a menu held it off: its close is an activation.
    private var roseUnderMenu = false
    /// The modes whose hint has shown for this picture since the last release; each mode's hint
    /// has its own moment.
    private var hintsShown: Set<CaptureMode> = []

    public init(mode: CaptureMode = .integrated) {
        self.mode = mode
    }

    /// Capture mode, captured, and the pointer has entered the picture since.
    public var isConfined: Bool { mode == .confined && isCaptured && pointerOnPicture }

    /// Whether a click on the picture would take input back: only Shift+Esc's release holds it
    /// off (not an interruption, a menu, focus or the picture's end).
    public var clickRecaptures: Bool { released && conditionsHold }

    /// The conditions for capture, Shift+Esc's release aside: the same in both modes.
    private var conditionsHold: Bool { conditionsBesideMenu && !menuOpen }

    /// The window, the app, the picture and the link: the conditions an open menu doesn't touch.
    private var conditionsBesideMenu: Bool { windowKey && appActive && picture && !interrupted }

    /// Captured but for an open menu.
    private var capturedBesideMenu: Bool { conditionsBesideMenu && !released }

    /// Whether Input ▸ Release Input has something to release: captured, or held off only by an
    /// open menu (any menu: the Input menu itself while the item is chosen).
    public var isReleasable: Bool { capturedBesideMenu }

    public mutating func apply(_ event: CaptureEvent) -> CaptureChange {
        let wasCaptured = isCaptured
        let wasBesideMenu = capturedBesideMenu
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
        case .release:
            released = true
            hintsShown.removeAll()
        // Only when nothing else holds capture off (`clickRecaptures`).
        // The click is on the picture: an entry.
        case .pictureClicked:
            if conditionsHold {
                released = false
                pointerOnPicture = true
            }
        case .away: pointerOnPicture = false
        case .menuOpen(let open):
            // A new menu session, not a submenu's report within one.
            if open, !menuOpen { roseUnderMenu = false }
            menuOpen = open
        case .pointerOnPicture(let on): pointerOnPicture = on
        case .mode(let new):
            if new != mode { pointerOnPicture = false }
            mode = new
        }
        isCaptured = conditionsHold && !released
        if wasCaptured, !isCaptured { pointerOnPicture = false }
        if menuOpen, capturedBesideMenu, !wasBesideMenu { roseUnderMenu = true }
        let rose = isCaptured && !wasCaptured
        // A menu closing alone is no activation: the window stayed key, and the host's focus
        // with it.
        let menuClosing = if case .menuOpen(false) = event { true } else { false }
        // The mode's state, the first time it holds since the last release or new picture
        // (a switch to Integrated while captured included).
        let hintState = mode == .confined ? isConfined : isCaptured
        return CaptureChange(
            showHint: hintState && hintsShown.insert(mode).inserted,
            activates: rose && (!menuClosing || roseUnderMenu))
    }
}
