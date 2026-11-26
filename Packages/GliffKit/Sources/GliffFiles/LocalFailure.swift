import Foundation

/// Why an operation on this Mac failed, from its `errno`, in sentences that name this Mac
/// rather than the host.
public enum LocalFailure: Equatable, Sendable {
    case permissionDenied
    case noSuchFile
    case noSpace
    case nameTaken
    case failure

    init(errno code: Int32) {
        self =
            switch code {
            case EACCES, EPERM, EROFS: .permissionDenied
            case ENOENT: .noSuchFile
            case ENOSPC, EDQUOT: .noSpace
            case EEXIST: .nameTaken
            default: .failure
            }
    }

    /// A Foundation error, by the POSIX code it carries (itself or underneath), else by its
    /// Cocoa code.
    init(error: any Error) {
        if let error = error as? POSIXError {
            self.init(errno: error.code.rawValue)
        } else if let error = error as? CocoaError, let posix = error.underlying as? POSIXError {
            self.init(errno: posix.code.rawValue)
        } else if let error = error as? CocoaError {
            self =
                switch error.code {
                case .fileWriteOutOfSpace: .noSpace
                case .fileReadNoPermission, .fileWriteNoPermission, .fileWriteVolumeReadOnly:
                    .permissionDenied
                case .fileNoSuchFile, .fileReadNoSuchFile: .noSuchFile
                case .fileWriteFileExists: .nameTaken
                default: .failure
                }
        } else {
            self = .failure
        }
    }

    /// The kinds a host has too are worded as the host's, with this Mac in its place.
    var message: String {
        switch self {
        case .permissionDenied: FilesError.permissionDenied.message(host: "this Mac")
        case .noSuchFile: FilesError.noSuchFile.message(host: "this Mac")
        case .noSpace: FilesError.noSpace.message(host: "this Mac")
        case .nameTaken: "An item with that name already exists on this Mac."
        case .failure: "This Mac couldn't read or write the item."
        }
    }
}
