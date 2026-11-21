/// The host reading one of our offers, for the progress shown over the picture (one activity
/// per offer, however many reads of it overlap).
public struct ClipboardActivity: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case running
        case done
        /// Why, in plain words (`TransferError.message`).
        case failed(String)
        case cancelled
    }

    /// Which read this is: a new one for each, so one that ends just as the last did is still
    /// news to the view.
    public var run: Int
    public var label: String
    /// Bytes read so far.
    public var done: UInt64
    public var state: State

    public init(run: Int = 0, label: String, done: UInt64, state: State) {
        (self.run, self.label, self.done, self.state) = (run, label, done, state)
    }

    /// How it ended: nil if it finished.
    static func state(after reason: TransferError?) -> State {
        switch reason {
        case nil: .done
        case .cancelled?: .cancelled
        case let reason?: .failed(reason.message)
        }
    }

    /// What a type is called on screen.
    public static func label(mime: String) -> String {
        switch mime {
        case ClipboardMimes.png: "image"
        case ClipboardMimes.html: "HTML"
        default: "text"
        }
    }
}

/// The serves of one Mac offer that overlap, reported as one activity once it has run a while.
struct ActivityRun {
    let id: Int
    let label: String
    let progress: TransferProgress
    var active = 1
    var reported = false
    /// The first reason a serve ended early.
    var failure: TransferError?
    var reporter: Task<Void, Never>?

    var activity: ClipboardActivity {
        ClipboardActivity(run: id, label: label, done: progress.done, state: .running)
    }
}
