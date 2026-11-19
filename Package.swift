// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MagpieTunnel",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .library(name: "MagpieTunnelCore", targets: ["MagpieTunnelCore"]),
        .executable(name: "MagpieTunnelDaemon", targets: ["magpie-tunneld"]),
        .executable(name: "MagpieTunnelStatus", targets: ["MagpieTunnelStatus"]),
    ],
    targets: [
        .target(
            name: "MagpieTunnelCore",
            path: "Sources/MagpieTunnelCore"
        ),
        .executableTarget(
            name: "magpie-tunneld",
            dependencies: ["MagpieTunnelCore"],
            path: "Sources/magpie-tunneld"
        ),
        .executableTarget(
            name: "MagpieTunnelStatus",
            dependencies: ["MagpieTunnelCore"],
            path: "Sources/MagpieTunnelStatus"
        ),
        .testTarget(
            name: "MagpieTunnelCoreTests",
            dependencies: ["MagpieTunnelCore"],
            path: "Tests/MagpieTunnelCoreTests"
        ),
        .testTarget(
            name: "MagpieTunnelDaemonTests",
            dependencies: ["MagpieTunnelCore"],
            path: "Tests/MagpieTunnelDaemonTests"
        ),
        .testTarget(
            name: "MagpieTunnelStatusTests",
            dependencies: ["MagpieTunnelCore", "MagpieTunnelStatus"],
            path: "Tests/MagpieTunnelStatusTests"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
