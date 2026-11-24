/// Whether a virtual screen's first picture is held back. The server starts the screen at its
/// own default (1920×1080 at 1, upstream `setup_output`), and the window's size replaces it a
/// moment later: that first picture is the wrong one. Held from the first StreamConfig, unless
/// the window's size is already that view, until:
/// - the first picture decoded from a frame after a StreamConfig with another view (the
///   picture in hand at that StreamConfig is still the old view's);
/// - a window size that leaves nothing to ask for (`ResizeRules.isSatisfied`), while the first
///   view is still in force;
/// - `limit` after the first frame, or after a Resize sent later (the server ignores a Resize
///   it finds unchanged).
///
/// A mirror is never held, and once shown the picture is never held again in that session.
struct PictureHold {
    /// How long a held picture waits once frames flow and its Resize has gone, in ms.
    static let limit: UInt64 = 2000

    private enum State {
        case notStarted
        /// The server's first view is in force; `since` is when the limit started counting.
        case holding(view: ResizeRules.View, since: UInt64?)
        /// Another view is in force: its first frame (`frame`) is awaited as a picture.
        case answered(frame: UInt64?, since: UInt64?)
        case done
    }

    private var state = State.notStarted

    var isHolding: Bool {
        switch state {
        case .holding, .answered: true
        case .notStarted, .done: false
        }
    }

    /// The first StreamConfig, with its view: whether the picture is held.
    mutating func started(view: ResizeRules.View, headless: Bool, satisfied: Bool) -> Bool {
        guard case .notStarted = state else { return false }
        state = headless && !satisfied ? .holding(view: view, since: nil) : .done
        return isHolding
    }

    /// A Resize went: once frames flow, the limit counts from now.
    mutating func resizeSent(now: UInt64) {
        guard case .holding(let view, .some) = state else { return }
        state = .holding(view: view, since: now)
    }

    /// A later StreamConfig, with its view.
    mutating func streamConfig(view: ResizeRules.View) {
        guard case .holding(let held, let since) = state, view != held else { return }
        state = .answered(frame: nil, since: since)
    }

    /// A video frame arrived.
    mutating func frame(id: UInt64, now: UInt64) {
        switch state {
        case .holding(let view, nil): state = .holding(view: view, since: now)
        case .answered(nil, let since): state = .answered(frame: id, since: since ?? now)
        default: break
        }
    }

    /// A frame decoded: whether its picture shows the picture. One that didn't decode to a
    /// picture leaves the next frame to show it.
    mutating func decoded(id: UInt64, picture: Bool) -> Bool {
        guard case .answered(id?, let since) = state else { return false }
        state = picture ? .done : .answered(frame: nil, since: since)
        return picture
    }

    /// Whether the picture shows now, past the limit. A clock step backwards counts as past.
    mutating func tick(now: UInt64) -> Bool {
        let since: UInt64?
        switch state {
        case .holding(_, let value), .answered(_, let value): since = value
        case .notStarted, .done: return false
        }
        guard let since, now < since || now - since >= Self.limit else { return false }
        state = .done
        return true
    }

    /// The window's size leaves nothing to ask for: whether that shows the picture. Only while
    /// the first view is in force, whose picture is the one in hand.
    mutating func satisfied() -> Bool {
        guard case .holding = state else { return false }
        state = .done
        return true
    }
}
