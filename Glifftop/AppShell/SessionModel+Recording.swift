import Foundation
import GliffSession

/// Recording the raw stream (Debug ▸ Record 5 Seconds).
extension SessionModel {
    /// Records the raw stream for five seconds into `directory`, from the next keyframe.
    func record(to directory: URL) {
        guard let session else { return }
        Task { await session.record(to: directory, for: .seconds(5)) }
    }

    #if DEBUG
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
