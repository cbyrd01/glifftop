import AppKit
import GliffClipboard
import Synchronization
import os

/// Answers a Mac app's paste of the remote's offer: fetches the type asked for while
/// the main thread runs a modal-style event loop, so Glifftop keeps drawing and Cancel
/// works, with `PasteProgressPanel` shown after a second. No data once the session has ended,
/// sharing is off or the app is quitting (AppKit may ask for promised data as it quits), nor
/// for a second paste while one runs.
final class PasteProvider: NSObject, NSPasteboardItemDataProvider {
    private static let log = Logger(subsystem: "me.cbyrd.Glifftop", category: "clipboard")
    /// The paste being fetched: a second one gets nothing; quitting cancels it.
    private static var running: Task<Void, Never>?
    /// Changes to the pasteboard that came while a paste was being answered, in order.
    private static var deferred: [() -> Void] = []
    private let bridge: ClipboardBridge
    private let offer: RemoteClipboardOffer
    private let host: String
    private let canFetch: () -> Bool

    init(bridge: ClipboardBridge, offer: RemoteClipboardOffer, host: String, canFetch: @escaping () -> Bool) {
        (self.bridge, self.offer, self.host, self.canFetch) = (bridge, offer, host, canFetch)
    }

    /// Runs `work`, which changes the pasteboard, now, or once the paste being answered has
    /// returned: the event loop it runs lets a newer host copy or a session's end arrive, and
    /// rewriting the pasteboard under that paste would lose it.
    static func afterPaste(_ work: @escaping () -> Void) {
        guard running == nil, deferred.isEmpty else { return deferred.append(work) }
        work()
    }

    /// Quitting: the running paste ends now, without data.
    static func cancelRunning() {
        running?.cancel()
    }

    func pasteboard(
        _ pasteboard: NSPasteboard?, item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        guard Self.running == nil, canFetch(),
            let mime = PasteboardTypes.remoteMime(for: type, in: offer.mimeTypes)
        else { return }
        switch fetch(mime) {
        case .success(let bytes):
            Self.log.info("remote clipboard pasted: \(bytes.count, privacy: .public) bytes")
            item.setData(Data(bytes), forType: type)
        case .failure(let error):
            Self.log.info("remote clipboard paste failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Fetches `mime`, pumping events until it ends; cancelled from the panel, by quitting, or
    /// once the session can no longer fetch.
    private func fetch(_ mime: String) -> Result<[UInt8], TransferError> {
        let outcome = Outcome()
        let progress = TransferProgress()
        let (bridge, serial) = (bridge, offer.serial)
        let task = Task.detached {
            do throws(TransferError) {
                outcome.set(.success(try await bridge.fetch(mime, serial: serial, progress: progress)))
            } catch {
                outcome.set(.failure(error))
            }
        }
        Self.running = task
        defer {
            Self.running = nil
            // After the provider has returned its data to AppKit; a paste begun meanwhile
            // drains them when it returns.
            if !Self.deferred.isEmpty {
                Task {
                    while Self.running == nil, !Self.deferred.isEmpty { Self.deferred.removeFirst()() }
                }
            }
        }
        let label = ClipboardActivity.label(mime: mime)
        let shownAt = ContinuousClock.now + .seconds(1)
        var panel: PasteProgressPanel?
        while true {
            if let result = outcome.result {
                if case .failure(let error) = result, error != .cancelled {
                    (panel ?? PasteProgressPanel(label: label, host: host)).fail(
                        error.message)
                } else {
                    panel?.close()
                }
                return result
            }
            if !canFetch() { task.cancel() }
            if let event = NSApp.nextEvent(
                matching: .any, until: Date(timeIntervalSinceNow: 0.05), inMode: .default, dequeue: true)
            {
                NSApp.sendEvent(event)
            }
            if panel == nil, ContinuousClock.now >= shownAt, !task.isCancelled {
                panel = PasteProgressPanel(label: label, host: host) { task.cancel() }
            }
            panel?.update(done: progress.done)
        }
    }

    /// How the fetch ended, set off the main thread and polled by the event loop.
    nonisolated private final class Outcome: Sendable {
        private let value = Mutex<Result<[UInt8], TransferError>?>(nil)
        var result: Result<[UInt8], TransferError>? { value.withLock { $0 } }
        func set(_ result: Result<[UInt8], TransferError>) { value.withLock { $0 = result } }
    }
}
