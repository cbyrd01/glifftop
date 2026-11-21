import Foundation
import GliffClipboard
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
            let stream = snapshot.phase == .streaming ? snapshot.stream : nil
            if stream != shownStream { shownStream = stream }
            if hasPicture != (picture != nil) { hasPicture = picture != nil }
            if snapshot.isInterrupted != isInterrupted { isInterrupted = snapshot.isInterrupted }
            let active = snapshot.phase != .idle
            if active != isActive { isActive = active }
            if windowSizing == nil, let sizing = Self.windowSizing(for: snapshot) { windowSizing = sizing }
            let output = snapshot.session?.output
            if output != outputName { outputName = output }
            if isSwitching, snapshot.phase == .streaming || snapshot.phase == .ended { isSwitching = false }
        }
    }
    /// How this session's window is sized, set once per session: a later view from
    /// the server never resizes the window. Nil until known (always known once streaming).
    private(set) var windowSizing: WindowSizing?
    /// Whether the session is a virtual screen (the window drives it). Follows `windowSizing`,
    /// so the View menu that reads it doesn't follow the stats.
    var isVirtual: Bool { windowSizing == .fillScreen }
    /// View ▸ Scale to Fit, for this window: from Settings at each connection from the form,
    /// kept when View ▸ Screen switches.
    var scaleToFit = false
    /// View ▸ Text Size, for this window, as Scale to Fit is. A change sends the window's size
    /// again at the new scale.
    var textSize = TextSize.mac {
        didSet { if textSize != oldValue { sendViewTarget() } }
    }
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
    /// The host's monitors, from Get Screens (or View ▸ Screen's Refresh Screen List).
    let screenList = ScreenList()
    /// The video view's drawable size in pixels, last reported (with `backingScale`). Changes
    /// every frame of a live resize, and no view reads it.
    @ObservationIgnored private var viewPixels: PixelSize?
    /// Whether the link is interrupted, set only when it changes (as `shownStream` is).
    private(set) var isInterrupted = false
    /// Input capture (keys and pointer) for this window's session.
    let capture = CaptureController()
    /// The shared clipboard for this window's session: "Share the clipboard" from Settings.
    let clipboard = ClipboardController(sharing: { AppSettings.shareClipboard })
    /// The stream on screen, set only when it changes: the stats change `snapshot` every
    /// second, and what reads `picture` (the window's size, the menus) needn't follow them. A
    /// View menu rebuilt every second loses the Enter Full Screen item macOS adds to it.
    private var shownStream: StreamInfo?
    /// The ssh destination as typed (for "Connecting to user@host…").
    private(set) var host = ""
    /// The session's destination, for View ▸ Screen's new session to the same host.
    private(set) var destination: SSHTarget?
    private var session: Session?
    /// Done once this session's and every earlier one's `run()` has returned (ssh reaped) and
    /// their statuses are folded: each new one also awaits the one it replaced.
    private var running: Task<Void, Never>?
    /// Set by `shutdown()`: no new session may start while the app quits.
    private var quitting = false

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
    /// View ▸ Show Statistics.
    var showsStatistics = true
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
        guard let shownStream, let renderer else { return nil }
        return (shownStream, renderer)
    }

    /// Starts a session with `target` (as typed) showing `screen`, the window's text size and
    /// Scale to Fit from Settings. Throws, with the reason to show, when the target isn't a
    /// valid ssh destination.
    func connect(to target: String, screen: ScreenChoice) throws(SSHTargetError) {
        let destination = try SSHTarget(target)
        guard !quitting else { return }
        scaleToFit = AppSettings.scaleToFit
        textSize = AppSettings.virtualTextSize
        start(destination, screen: screen)
    }

    /// Ends any session, then starts one with `destination` showing `screen`.
    func start(_ destination: SSHTarget, screen: ScreenChoice) {
        guard !quitting else {
            isSwitching = false
            return
        }
        // A listing still running would ask for a second ssh approval beside the session's.
        screenList.stop()
        disconnect()
        self.destination = destination
        screenChoice = screen
        host = destination.value
        slot = PictureSlot()
        cursor = CursorSlot()
        windowSizing = nil
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
        // Leave the connect form now, not when the session's own `.connecting` arrives.
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
                backingScale: backingScale, textFactor: textSize.factor))
    }

    /// A virtual screen fills the screen; a mirror is sized for its first view within its
    /// monitor (`SessionSnapshot.mirrorSize`). Nil until one is known.
    private static func windowSizing(for snapshot: SessionSnapshot) -> WindowSizing? {
        if snapshot.session?.headless == true { return .fillScreen }
        guard snapshot.phase == .streaming, let size = snapshot.mirrorSize else { return nil }
        return .monitor(size)
    }

    /// Says Bye and ends the session (no-op once it has ended). Keys the remote holds are let
    /// go first: their releases are queued ahead of the Bye.
    func disconnect() {
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

    /// Back to the connect form after a session ended.
    func reset() {
        disconnect()
        session = nil
        destination = nil
        isSwitching = false
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

    /// Records the raw stream for five seconds into `directory`, from the next keyframe.
    func record(to directory: URL) {
        guard let session else { return }
        Task { await session.record(to: directory, for: .seconds(5)) }
    }

    #if DEBUG
        // MARK: Debug ▸ Record 5 Seconds

        /// Set when a recording needs a folder chosen first; the window shows the folder picker.
        var choosingRecordingsDirectory = false
        private static let recordingsDirectoryKey = "recordingsDirectory"

        func recordFiveSeconds() {
            // A folder deleted since it was chosen asks again rather than failing silently.
            if let directory = UserDefaults.standard.url(forKey: Self.recordingsDirectoryKey),
                FileManager.default.fileExists(atPath: directory.path(percentEncoded: false))
            {
                record(to: directory)
            } else {
                choosingRecordingsDirectory = true
            }
        }

        /// The folder picked for recordings: remembered, and recorded into now.
        func useRecordingsDirectory(_ directory: URL) {
            UserDefaults.standard.set(directory, forKey: Self.recordingsDirectoryKey)
            record(to: directory)
        }
    #endif
}
