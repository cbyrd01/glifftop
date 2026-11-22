import Foundation
import GliffClipboard
import GliffMachines
import GliffProtocol
import GliffSession
import GliffTransport
import GliffVideo
import Metal
import Observation
import os

/// One window's session: starts it, folds its statuses into `snapshot`, and stops it.
@Observable final class SessionModel {
    private(set) var snapshot = SessionSnapshot() {
        didSet {
            let phaseChanged = snapshot.phase != phase
            let stream = snapshot.phase == .streaming ? snapshot.stream : nil
            if stream != shownStream { shownStream = stream }
            if let stream { lastStream = stream }
            refreshHasPicture()
            if snapshot.isInterrupted != isInterrupted { isInterrupted = snapshot.isInterrupted }
            if snapshot.phase != phase { phase = snapshot.phase }
            if snapshot.clipboard != clipboardActivity { clipboardActivity = snapshot.clipboard }
            let active = snapshot.phase != .idle
            if active != isActive { isActive = active }
            // A reconnect's may show another monitor: Actual Size fits the new one.
            let resizes = windowSizing == nil || keepsWindow && phaseChanged && snapshot.phase == .streaming
            if resizes, let sizing = Self.windowSizing(for: snapshot), sizing != windowSizing {
                windowSizing = sizing
            }
            let output = snapshot.session?.output
            if output != outputName { outputName = output }
            if isSwitching, snapshot.phase == .streaming || snapshot.phase == .ended { isSwitching = false }
            if snapshot.phase == .streaming, !recorded {
                recorded = true
                recordConnection()
            }
            if phaseChanged { sessionPhaseChanged() }
        }
    }
    /// How this session's window is sized, set once per session: a later view from
    /// the server never resizes the window. Nil until known (always known once streaming).
    private(set) var windowSizing: WindowSizing?
    /// Whether the session is a virtual screen (the window drives it). Follows `windowSizing`,
    /// so the View menu that reads it doesn't follow the stats.
    var isVirtual: Bool { windowSizing == .fillScreen }
    /// View ▸ Scale to Fit, for this window: the machine's option at each connection, kept when
    /// View ▸ Screen switches, and a change kept on the machine.
    var scaleToFit = false {
        didSet { if scaleToFit != oldValue { updateMachine { $0.scaleToFit = scaleToFit } } }
    }
    /// View ▸ Text Size, for this window, as Scale to Fit is. A change sends the window's size
    /// again at the new scale.
    var textSize = TextSize.mac {
        didSet {
            guard textSize != oldValue else { return }
            sendViewTarget()
            updateMachine { $0.textSize = textSize }
        }
    }
    /// View ▸ Resolution, a virtual screen's, for this window, as Text Size is: a change sends
    /// the window's size again at the new resolution.
    var resolution = VirtualResolution.automatic {
        didSet {
            guard resolution != oldValue else { return }
            sendViewTarget()
            updateMachine { $0.resolution = resolution }
        }
    }
    /// Whether the picture is drawn scaled to the window: Scale to Fit, or a virtual screen's
    /// picture at Standard (half the window's pixels a side), as the picture shown (a held one
    /// while reconnecting) shows it, so a change draws right until the server answers.
    var drawsScaled: Bool {
        guard !scaleToFit else { return true }
        guard isVirtual, let backingScale, let stream = picture?.stream else { return false }
        return ViewTarget.isStandardPicture(
            screenScale: stream.screenScale, backingScale: backingScale, textFactor: textSize.factor)
    }
    /// Whether a lost link is tried again, for this window, from the machine's option.
    var reconnects = true {
        didSet { reconnectsChanged() }
    }
    /// The saved machines, kept in `UserDefaults`.
    let machines = MachineStore()
    /// Set while a connection sets the window's options from a machine's: not changes to keep.
    @ObservationIgnored var applyingOptions = false
    /// The machine sheet (New Machine…, Edit…, Connection ▸ Edit Machine…), while shown.
    var machineEdit: MachineEdit?
    /// The session's output as the server names it (`DP-2`, `HEADLESS-1`), set only when it
    /// changes: the View menu reads it.
    private(set) var outputName: String?
    /// The window's backing scale, from the video view, set only when it changes: View ▸ Text
    /// Size shows the remote scale for it.
    private(set) var backingScale: Double?
    /// Set while View ▸ Screen's new session connects, until it streams or ends: the window
    /// stays in full screen meanwhile, though there's no picture. Set by `switchScreen`.
    var isSwitching = false
    /// What the last session started showing, set at each start and kept after it ends.
    private(set) var screenChoice = ScreenChoice.focused
    /// Another screen the sheet saved for the session's machine: Try Again shows it, a
    /// reconnect's try the session's own. Cleared by any other start.
    @ObservationIgnored var sheetScreen: ScreenChoice?
    /// The host's monitors, from Get Screens (or View ▸ Screen's Refresh Screen List).
    let screenList = ScreenList()
    /// The video view's drawable size in pixels, last reported (with `backingScale`). Changes
    /// every frame of a live resize, and no view reads it.
    @ObservationIgnored private var viewPixels: PixelSize?
    /// Whether the link is interrupted, set only when it changes (as `shownStream` is).
    private(set) var isInterrupted = false
    /// The session's phase, set only when it changes: the title, the toolbar and the menus read it.
    private(set) var phase = SessionSnapshot.Phase.idle
    /// The host's read of the Mac clipboard, set only when it changes: the toolbar shows it.
    private(set) var clipboardActivity: ClipboardActivity?
    /// Input capture (keys and pointer) for this window's session.
    let capture = CaptureController()
    /// The shared clipboard for this window's session: "Share the clipboard" from Settings.
    let clipboard = ClipboardController(
        sharing: { AppSettings.shareClipboard }, includePasswords: { AppSettings.includePasswords })
    /// The stream on screen, set only when it changes: the stats change `snapshot` every
    /// second, and what reads `picture` (the window's size, the menus) needn't follow them. A
    /// View menu rebuilt every second loses the Enter Full Screen item macOS adds to it.
    private var shownStream: StreamInfo?
    /// The ssh destination as typed (for "Connecting to user@host…").
    private(set) var host = ""
    /// The session's destination, for View ▸ Screen's new session to the same host.
    private(set) var destination: SSHTarget?
    private(set) var session: Session?
    /// Done once this session's and every earlier one's `run()` has returned (ssh reaped) and
    /// their statuses are folded: each new one also awaits the one it replaced.
    private var running: Task<Void, Never>?
    /// Set by `shutdown()`: no new session may start while the app quits.
    private(set) var quitting = false
    /// Whether this session has streamed (and been recorded on its machine).
    @ObservationIgnored private(set) var recorded = false

    // Reconnect (`SessionModel+Reconnect.swift`).
    /// The reconnect under way, while a lost session is tried again.
    var reconnectRun: ReconnectRun?
    /// Where the reconnect is, when its countdown ends, and why the session was lost.
    var reconnectState: ReconnectState?
    var reconnectDeadline: Date?
    var reconnectEnd: SessionEnd?
    /// The tries ran out: the ended screen says so.
    var gaveUp = false
    /// Shown for a few seconds after a virtual screen comes back as a new one.
    var showsVirtualNotice = false
    /// The last picture's slot and stream, shown while reconnecting.
    var heldPicture: (slot: PictureSlot, stream: StreamInfo)?
    /// The session is a reconnect's try: the window keeps its size.
    private(set) var keepsWindow = false
    @ObservationIgnored var lastStream: StreamInfo?
    @ObservationIgnored var networkUsable = true
    /// Wake and network changes, for the probe and the reconnect.
    private let wake = WakeObserver()

    init() {
        wake.onWake = { [weak self] in self?.woke() }
        wake.onNetwork = { [weak self] in self?.networkChanged($0) }
    }

    /// A reconnect outliving its window would wait on a network nobody reports any more.
    isolated deinit {
        reconnectRun?.task?.cancel()
        reconnectRun?.networkChanges.finish()
    }

    /// The current session's latest picture, which the video view draws. A new one per
    /// session, so a new session never shows the last one's picture.
    private(set) var slot = PictureSlot()
    /// The current session's latest cursor shape, which the video view shows while captured. A
    /// new one per session, as `slot` is.
    private(set) var cursor = CursorSlot()
    #if DEBUG
        /// Debug ▸ Test Cursor Shape: the video view shows `TestCursor`'s crosshair instead.
        var testCursorShape = false
    #endif

    /// The shapes the video view shows: the session's, or (Debug) the test crosshair.
    var viewCursor: CursorSlot {
        #if DEBUG
            if testCursorShape { return TestCursor.slot }
        #endif
        return cursor
    }
    /// Draws pictures into the video view: made on the first connect, then kept.
    private(set) var renderer: PictureRenderer?
    /// Connection Info's popover (⌘I, the toolbar's ⓘ); closed at each session's start and at
    /// Back.
    var showsConnectionInfo = false
    /// The toolbar's Share the clipboard is asking first (the alert is the window's).
    var confirmingShare = false
    /// The clipboard read whose failure was already shown its 3 s (`ClipboardReadView`), shared
    /// by the toolbar and the status bar; a new session's runs count again.
    var dismissedClipboardRun: Int?
    /// Counts View ▸ Actual Size: each one fits the window to the remote view again.
    private(set) var actualSizeRequests = 0

    private static let logger = Logger(subsystem: "me.cbyrd.Glifftop", category: "session")

    /// Whether there's a picture, set only when that flips: what the menus read. `picture`
    /// changes with each StreamConfig (every settled resize on a virtual screen), and a View
    /// menu rebuilt for it loses Enter Full Screen.
    private(set) var hasPicture = false

    /// Whether a session has been started and not yet put away with `reset()`; set only when
    /// it changes (as `shownStream` is), so the window and the Debug menu don't follow the stats.
    private(set) var isActive = false

    /// What the picture is drawn from, while it is shown: streaming, with a stream and a
    /// renderer. The one test for the picture, and for the freely resizable window.
    var picture: (stream: StreamInfo, renderer: PictureRenderer)? {
        guard let renderer else { return nil }
        if let shownStream { return (shownStream, renderer) }
        if let heldPicture { return (heldPicture.stream, renderer) }
        return nil
    }

    /// Sets `hasPicture` when `picture` comes or goes.
    func refreshHasPicture() {
        if hasPicture != (picture != nil) { hasPicture = picture != nil }
    }

    /// Ends any session, then starts one with `destination` showing `screen`; a reconnect's
    /// try keeps the window's size.
    func start(_ destination: SSHTarget, screen: ScreenChoice, reconnecting: Bool = false) {
        guard !quitting else {
            isSwitching = false
            return
        }
        // A listing still running would ask for a second ssh approval beside the session's.
        screenList.stop()
        if !reconnecting {
            cancelReconnect()
            (gaveUp, sheetScreen) = (false, nil)
        }
        endSession()
        (showsConnectionInfo, dismissedClipboardRun, keepsWindow) = (false, nil, reconnecting)
        recorded = false
        self.destination = destination
        screenChoice = screen
        host = destination.value
        slot = PictureSlot()
        cursor = CursorSlot()
        if !reconnecting { windowSizing = nil }
        viewPixels = nil
        let decoder: VideoToolboxDecoder
        do throws(VideoError) {
            decoder = try makeDecoder()
        } catch {
            // No GPU video, no session: say why instead of connecting to show nothing.
            Self.logger.error("video setup failed: \(String(describing: error), privacy: .public)")
            reset()
            snapshot.apply(.ended(.decoderFailed(error.setupFailure)))
            return
        }
        let pixels = DisplayMetrics.largestDisplayPixels()
        // Hello carries no keymap: one the server's xkeyboard-config can't compile would fail
        // its setup, where a Keymap that fails is ignored (it keeps US). The Mac's layout
        // goes as a Keymap straight after, queued before the session runs.
        let session = Session(
            transport: SystemSSHTransport(
                command: SSHCommand(target: destination, serverArguments: screen.serverArguments)),
            configuration: SessionConfiguration(maxWidth: pixels.width, maxHeight: pixels.height),
            decoder: decoder, cursor: cursor, clipboard: ClipboardSetup(source: PasteboardSource()))
        self.session = session
        capture.attach { session.send($0) }
        clipboard.attach(session, host: destination.value)
        // Leave the machines now, not when the session's own `.connecting` arrives.
        snapshot = SessionSnapshot()
        snapshot.apply(.connecting)
        running = Task { [previous = running] in
            async let running: Void = session.run()
            // A replaced session's last statuses (its `.ended`) must not reach the new one's.
            for await status in session.status where self.session === session {
                switch status {
                case .ended: clipboard.detach()
                case .clipboardOffer(let offer): clipboard.remoteOffered(offer)
                default: break
                }
                snapshot.apply(status)
            }
            await running
            await previous?.value
        }
    }

    /// The decoder for a new session, publishing into `slot`, on the renderer's device.
    private func makeDecoder() throws(VideoError) -> VideoToolboxDecoder {
        try VideoToolboxDecoder(device: try sharedRenderer().device, slot: slot)
    }

    /// `renderer`, made on first use.
    private func sharedRenderer() throws(VideoError) -> PictureRenderer {
        if let renderer { return renderer }
        guard let device = MTLCreateSystemDefaultDevice() else { throw .noMetalDevice }
        let made = try PictureRenderer(device: device)
        renderer = made
        return made
    }

    /// View ▸ Actual Size.
    func actualSize() {
        actualSizeRequests += 1
    }

    /// The video view's drawable (pixels) and backing scale: the remote screen follows it.
    func viewTargetChanged(_ pixels: PixelSize, backingScale: Double) {
        viewPixels = pixels
        if backingScale != self.backingScale { self.backingScale = backingScale }
        sendViewTarget()
    }

    private func sendViewTarget() {
        guard let session, let viewPixels, let backingScale else { return }
        session.setViewTarget(
            ViewTarget(
                width: UInt32(clamping: viewPixels.width), height: UInt32(clamping: viewPixels.height),
                backingScale: backingScale, textFactor: textSize.factor, resolution: resolution))
    }

    /// A virtual screen fills the screen; a mirror is sized for its first view within its
    /// monitor (`SessionSnapshot.mirrorSize`). Nil until one is known.
    private static func windowSizing(for snapshot: SessionSnapshot) -> WindowSizing? {
        if snapshot.session?.headless == true { return .fillScreen }
        guard snapshot.phase == .streaming, let size = snapshot.mirrorSize else { return nil }
        return .monitor(size)
    }

    /// Disconnect: stops any reconnect, then ends the session (`endSession`).
    func disconnect() {
        cancelReconnect()
        endSession()
    }

    /// Says Bye and ends the session (no-op once it has ended), leaving a reconnect be. Keys the
    /// remote holds are let go first: their releases are queued ahead of the Bye.
    func endSession() {
        capture.detach()
        clipboard.detach()
        guard let session else { return }
        Task { await session.disconnect() }
    }

    /// Says Bye and waits for the session to end and ssh to exit, for quitting. Bounded: the
    /// transport stops ssh with SIGTERM, then SIGKILL, within a few seconds.
    func shutdown() async {
        quitting = true
        disconnect()
        await running?.value
    }

    /// Back to the machines after a session ended.
    func reset() {
        disconnect()
        session = nil
        destination = nil
        isSwitching = false
        (showsConnectionInfo, dismissedClipboardRun, gaveUp) = (false, nil, false)
        host = ""
        // The old pool's textures go with the old slot and session.
        slot = PictureSlot()
        cursor = CursorSlot()
        windowSizing = nil
        viewPixels = nil
        snapshot = SessionSnapshot()
    }

    /// Cancel on the host's read of the Mac clipboard: what is being served is aborted.
    func cancelClipboardServing() {
        guard let bridge = session?.clipboard else { return }
        Task { await bridge.cancelServing() }
    }

    #if DEBUG
        /// Set when a recording needs a folder chosen first; the window shows the folder picker
        /// (`SessionModel+Recording.swift`).
        var choosingRecordingsDirectory = false
    #endif
}
