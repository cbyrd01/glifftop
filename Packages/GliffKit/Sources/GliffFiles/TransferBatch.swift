public import Foundation

/// What a batch copies: one drop, drag or Upload's items.
public enum TransferRequest: Sendable {
    /// This Mac's items into a folder on the host; `clash` settles a name already there.
    case upload([URL], to: RemotePath, clash: NameClashPolicy)
    /// The host's items into a folder on this Mac, where a name already there gets " 2".
    case download([RemotePath], to: URL)
}

/// One batch in a host's queue, and how far it has come.
public final class TransferBatch: Identifiable, Sendable {
    public let id = UUID()
    public let request: TransferRequest
    public let progress = TransferProgress()

    init(request: TransferRequest) { self.request = request }
}

/// A batch with what its tries need: its plan once made, the top-level items earlier tries
/// finished, and how an upload settles a taken name.
struct QueuedBatch {
    enum Plan {
        case upload(UploadPlan)
        case download(DownloadPlan)
    }

    let batch: TransferBatch
    /// Held while the batch is queued or running.
    var user: FilesUser?
    var plan: Plan?
    var done = 0
    /// The request's, or, when it asks, the asking of the window that last tried again.
    var clash: NameClashPolicy

    init(batch: TransferBatch, user: FilesUser) {
        (self.batch, self.user) = (batch, user)
        if case .upload(_, _, let clash) = batch.request {
            self.clash = clash
        } else {
            self.clash = .keepBoth
        }
    }
}
