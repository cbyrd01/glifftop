#if os(macOS)
    import Foundation
    import Testing

    @testable import GliffFiles

    @Suite struct QuarantineTests {
        func quarantine(of url: URL) -> String? {
            let path = url.path(percentEncoded: false)
            let size = getxattr(path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW)
            guard size > 0 else { return nil }
            var bytes = [UInt8](repeating: 0, count: size)
            _ = getxattr(path, "com.apple.quarantine", &bytes, size, 0, XATTR_NOFOLLOW)
            return String(decoding: bytes, as: UTF8.self)
        }

        @Test func aDownloadIsQuarantined() throws {
            let folder = try TemporaryFolder()
            defer { folder.remove() }
            let file = try folder.file("report.pdf", "bytes")
            #expect(quarantine(of: file) == nil)
            try Quarantine.apply(to: file)
            #expect(quarantine(of: file) != nil)
            let properties = try #require(
                try file.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties)
            #expect(properties["LSQuarantineAgentName"] as? String == "Glifftop")
            #expect(properties["LSQuarantineType"] as? String == "LSQuarantineTypeOtherDownload")
            #expect(properties["LSQuarantineOriginURL"] == nil && properties["LSQuarantineDataURL"] == nil)
        }

        @Test func aFolderIsQuarantined() throws {
            let folder = try TemporaryFolder()
            defer { folder.remove() }
            try Quarantine.apply(to: folder.url)
            #expect(quarantine(of: folder.url) != nil)
        }
    }
#endif
