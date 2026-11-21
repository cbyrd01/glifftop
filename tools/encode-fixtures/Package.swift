// swift-tools-version: 6.4
import PackageDescription

// The same strict settings as GliffKit.
let strictSettings: [SwiftSetting] = [
    .treatAllWarnings(as: .error),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("InternalImportsByDefault"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
]

// Test tooling: encodes GliffVideoTests' synthetic planes into small H.264 streams with
// VideoToolbox. Run by hand; its output is committed (see README.md).
let package = Package(
    name: "encode-fixtures",
    platforms: [.macOS(.v27)],
    targets: [
        .target(name: "FixtureEncoding", swiftSettings: strictSettings),
        .executableTarget(
            name: "encode-fixtures", dependencies: ["FixtureEncoding"], swiftSettings: strictSettings),
        .testTarget(
            name: "FixtureEncodingTests", dependencies: ["FixtureEncoding"], swiftSettings: strictSettings),
    ]
)
