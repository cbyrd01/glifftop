// swift-tools-version: 6.4
import PackageDescription

// Applied to every target, test targets included. No default isolation: GliffKit code
// runs off the main thread and also compiles for iOS.
let strictSettings: [SwiftSetting] = [
    .treatAllWarnings(as: .error),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("InternalImportsByDefault"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
]

let package = Package(
    name: "GliffKit",
    platforms: [.macOS(.v27), .iOS(.v27)],
    products: [
        // The app links only GliffKit; each module joins its target list (GliffTestSupport,
        // for tests only, never does).
        .library(
            name: "GliffKit",
            targets: [
                "GliffProtocol", "GliffTransport", "GliffVideo", "GliffInput", "GliffClipboard",
                "GliffSession", "GliffMachines",
            ])
    ],
    targets: [
        .target(name: "GliffProtocol", exclude: ["README.md"], swiftSettings: strictSettings),
        .testTarget(
            name: "GliffProtocolTests",
            dependencies: ["GliffProtocol"],
            resources: [.copy("Fixtures")],
            swiftSettings: strictSettings
        ),
        .target(name: "GliffTransport", exclude: ["README.md"], swiftSettings: strictSettings),
        .testTarget(
            name: "GliffTransportTests", dependencies: ["GliffTransport"], swiftSettings: strictSettings),
        .target(
            name: "GliffVideo", dependencies: ["GliffProtocol"], exclude: ["README.md"],
            resources: [.process("Shaders")], swiftSettings: strictSettings),
        .testTarget(
            name: "GliffVideoTests",
            dependencies: ["GliffVideo", "GliffProtocol"],
            resources: [.copy("Fixtures")],
            swiftSettings: strictSettings
        ),
        .target(
            name: "GliffInput", dependencies: ["GliffProtocol"], exclude: ["README.md"],
            swiftSettings: strictSettings),
        .testTarget(
            name: "GliffInputTests", dependencies: ["GliffInput", "GliffProtocol"],
            swiftSettings: strictSettings),
        .target(
            name: "GliffClipboard", dependencies: ["GliffProtocol"], exclude: ["README.md"],
            swiftSettings: strictSettings),
        .testTarget(
            name: "GliffClipboardTests",
            dependencies: ["GliffClipboard", "GliffProtocol", "GliffTestSupport"],
            swiftSettings: strictSettings),
        .target(
            name: "GliffSession",
            dependencies: ["GliffProtocol", "GliffTransport", "GliffVideo", "GliffInput", "GliffClipboard"],
            exclude: ["README.md"], swiftSettings: strictSettings),
        .testTarget(
            name: "GliffSessionTests",
            dependencies: [
                "GliffSession", "GliffProtocol", "GliffTransport", "GliffVideo", "GliffInput",
                "GliffClipboard", "GliffTestSupport",
            ],
            swiftSettings: strictSettings),
        .target(
            name: "GliffMachines", dependencies: ["GliffTransport", "GliffSession"], exclude: ["README.md"],
            swiftSettings: strictSettings),
        .testTarget(
            name: "GliffMachinesTests", dependencies: ["GliffMachines", "GliffTransport", "GliffSession"],
            swiftSettings: strictSettings),
        // Test doubles shared by the test targets (a clock tests move by hand); not in the product.
        .target(name: "GliffTestSupport", exclude: ["README.md"], swiftSettings: strictSettings),
    ]
)
