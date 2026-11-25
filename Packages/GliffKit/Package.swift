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
        // The app links only GliffKit; each module joins its target list, but GliffTestSupport
        // (for tests only) and GliffAskpass (for the app's helper tool, which links only it).
        .library(
            name: "GliffKit",
            targets: [
                "GliffProtocol", "GliffTransport", "GliffVideo", "GliffInput", "GliffClipboard",
                "GliffSession", "GliffMachines", "GliffPorts",
            ]),
        // The askpass helper's logic, for the app's helper tool, which links only this.
        .library(name: "GliffAskpass", targets: ["GliffAskpass"]),
    ],
    targets: [
        .target(name: "GliffProtocol", exclude: ["README.md"], swiftSettings: strictSettings),
        .testTarget(
            name: "GliffProtocolTests",
            dependencies: ["GliffProtocol"],
            resources: [.copy("Fixtures")],
            swiftSettings: strictSettings
        ),
        .target(name: "GliffAskpass", exclude: ["README.md"], swiftSettings: strictSettings),
        // The helper as SwiftPM builds it, for the tests and the live check; the app embeds its own.
        .executableTarget(
            name: "glifftop-askpass-swiftpm", dependencies: ["GliffAskpass"], exclude: ["README.md"],
            swiftSettings: strictSettings),
        .testTarget(
            name: "GliffAskpassTests", dependencies: ["GliffAskpass", "GliffTestSupport"],
            swiftSettings: strictSettings),
        .target(
            name: "GliffTransport", dependencies: ["GliffProtocol", "GliffAskpass"], exclude: ["README.md"],
            swiftSettings: strictSettings),
        .testTarget(
            name: "GliffTransportTests",
            dependencies: ["GliffTransport", "GliffAskpass", "GliffTestSupport"],
            swiftSettings: strictSettings),
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
            name: "GliffMachines", dependencies: ["GliffTransport", "GliffSession", "GliffClipboard"],
            exclude: ["README.md"],
            swiftSettings: strictSettings),
        .testTarget(
            name: "GliffMachinesTests",
            dependencies: ["GliffMachines", "GliffTransport", "GliffSession", "GliffClipboard"],
            swiftSettings: strictSettings),
        .target(
            name: "GliffPorts", dependencies: ["GliffTransport"], exclude: ["README.md"],
            swiftSettings: strictSettings),
        .testTarget(
            name: "GliffPortsTests", dependencies: ["GliffPorts", "GliffTransport", "GliffTestSupport"],
            resources: [.copy("Fixtures")], swiftSettings: strictSettings),
        // Test doubles shared by the test targets (a clock tests move by hand); not in the product.
        .target(name: "GliffTestSupport", exclude: ["README.md"], swiftSettings: strictSettings),
    ]
)
