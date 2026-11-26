#if os(macOS)
    public import Foundation

    /// Marks a download as a browser marks its downloads: `com.apple.quarantine`, agent
    /// "Glifftop", type "other download", with no origin or data URL.
    public enum Quarantine {
        public static func apply(to url: URL) throws(FilesError) {
            var values = URLResourceValues()
            // The values of LaunchServices' kLSQuarantine constants, which Foundation doesn't name.
            values.quarantineProperties = [
                "LSQuarantineAgentName": "Glifftop", "LSQuarantineType": "LSQuarantineTypeOtherDownload",
            ]
            var url = url
            do {
                try url.setResourceValues(values)
            } catch {
                throw .local(LocalFailure(error: error))
            }
        }
    }
#endif
