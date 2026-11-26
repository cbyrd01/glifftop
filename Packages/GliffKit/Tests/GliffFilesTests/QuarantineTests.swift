#if os(macOS)
    import Foundation
    import Testing

    @testable import GliffFiles

    @Suite struct QuarantineTests {
        @Test func aDownloadIsQuarantined() throws {
            let folder = try TemporaryFolder()
            defer { folder.remove() }
            let file = try folder.file("report.pdf", "bytes")
            #expect(TemporaryFolder.quarantine(of: file) == nil)
            try Quarantine.apply(to: file)
            #expect(TemporaryFolder.quarantine(of: file) != nil)
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
            #expect(TemporaryFolder.quarantine(of: folder.url) != nil)
        }
    }
#endif
