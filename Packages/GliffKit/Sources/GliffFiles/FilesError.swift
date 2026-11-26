import Foundation
import GliffSFTP
import GliffTransport

/// Why a file operation or a transfer failed. Each has one sentence in Glifftop's words
/// (`message(host:)`); the host's own STATUS text is never kept or shown.
public enum FilesError: Error, Equatable, Sendable {
    case permissionDenied
    case noSuchFile
    /// The host refused (SFTP's generic FAILURE, or a code Glifftop doesn't know).
    case failure
    /// The file server ended.
    case ended
    /// The link to the host was lost.
    case connectionLost
    /// The file server broke a rule of the protocol.
    case protocolBroken
    /// The login shell printed text before the file server started.
    case textBeforeVersion
    /// A request went unanswered past its time limit.
    case timedOut
    case unsupported
    case noSpace
    case changedWhileCopying
    case cancelled
    /// A batch past `TransferLimits`.
    case tooLarge
    /// An operation on this Mac failed.
    case local(LocalFailure)

    /// The error for a STATUS code that isn't OK; the host's text is never kept.
    init(status code: SFTPStatusCode) {
        self =
            switch code {
            case .permissionDenied: .permissionDenied
            case .noSuchFile: .noSuchFile
            case .unsupported: .unsupported
            case .noConnection, .connectionLost: .connectionLost
            default: .failure
            }
    }

    /// A stream that failed: a refused subsystem or channel, or the server's own exit, is the
    /// file server ending; any other failure of ssh's (the link, a sign-in, a host key) is a lost
    /// connection.
    init(transport error: TransportError) {
        self =
            switch error {
            case .cancelled: .cancelled
            case .exited(_, .other), .exited(_, .channelRefused), .exited(_, .serverNotInstalled): .ended
            case .exited: .connectionLost
            default: .ended
            }
    }

    /// Why reading the stream stopped: a broken rule, or the stream's own failure.
    init(reading error: any Error) {
        self =
            switch error {
            case SFTPError.textBeforeVersion: .textBeforeVersion
            case is SFTPError: .protocolBroken
            case let error as TransportError: FilesError(transport: error)
            default: .ended
            }
    }

    public func message(host: String) -> String {
        switch self {
        case .permissionDenied: "You don't have permission to do that on \(host)."
        case .noSuchFile: "The item no longer exists on \(host)."
        case .failure: "\(host) refused the request."
        case .ended: "\(host)'s file server ended."
        case .connectionLost: "The connection to \(host) was lost."
        case .protocolBroken: "\(host)'s file server sent a reply Glifftop can't read."
        case .textBeforeVersion:
            "\(host)'s shell printed text before the file server started (check its startup files)."
        case .timedOut: "\(host)'s file server stopped answering."
        case .unsupported: "\(host)'s file server doesn't support this."
        case .noSpace: "There isn't enough space on \(host) for these items."
        case .changedWhileCopying: "An item changed on \(host) while it was copied."
        case .cancelled: "The transfer was stopped."
        case .tooLarge:
            "There are too many items to copy at once (at most \(TransferLimits.maxEntries.formatted(.number.locale(Locale(identifier: "en_US")))), \(TransferLimits.maxDepth) folders deep)."
        case .local(let failure): failure.message
        }
    }
}
