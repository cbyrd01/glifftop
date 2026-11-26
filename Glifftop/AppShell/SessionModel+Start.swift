import GliffClipboard
import GliffSession
import GliffTransport
import GliffVideo

/// A new session's construction and its input's attach, for `start`.
extension SessionModel {
    /// The session to `destination` showing `screen`, publishing into this start's slots.
    func makeSession(
        to destination: SSHTarget, screen: ScreenChoice, reconnecting: Bool, decoder: VideoToolboxDecoder
    ) -> Session {
        let pixels = DisplayMetrics.largestDisplayPixels()
        // Hello carries no keymap: one the server's xkeyboard-config can't compile would fail
        // its setup, where a Keymap that fails is ignored (it keeps US). The Mac's layout
        // goes as a Keymap straight after, queued before the session runs.
        return Session(
            transport: AppConnections.session(
                on: destination, serverArguments: screen.serverArguments, fresh: asksAgain(reconnecting),
                asker: signIn.queue),
            configuration: SessionConfiguration(maxWidth: pixels.width, maxHeight: pixels.height),
            decoder: decoder, cursor: cursor, pointer: remotePointer,
            clipboard: ClipboardSetup(source: PasteboardSource()), observer: protocolObserver,
            barrier: AppConnections.inputBarrier)
    }

    /// The window's keys, pointer and clipboard to `session`, whose host is `host`.
    func attachInput(to session: Session) {
        capture.attach(
            target: { [weak self] in self?.activationTarget(macPointer: $0) }, send: { session.send($0) },
            pointer: remotePointer)
        clipboard.attach(session, host: host)
    }
}
