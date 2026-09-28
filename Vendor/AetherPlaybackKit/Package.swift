// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AetherPlaybackKit",
    platforms: [
        .tvOS(.v17),
        .visionOS(.v2),
    ],
    products: [
        // Keep the Aether implementation in its own runtime module while allowing
        // SwiftPM/Xcode to own the complete transitive binary-framework graph.
        .library(
            name: "AetherPlaybackBridge",
            type: .dynamic,
            targets: ["AetherPlaybackBridge"]
        ),
    ],
    dependencies: [
        .package(path: "../AetherEngine"),
    ],
    targets: [
        .target(
            name: "AetherPlaybackBridge",
            dependencies: [
                .product(name: "AetherEngine", package: "AetherEngine"),
            ],
            path: "Sources/AetherPlaybackBridge"
        ),
    ]
)
