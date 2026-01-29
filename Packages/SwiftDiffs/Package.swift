// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SwiftDiffs",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .visionOS(.v1)
    ],
    products: [
        .library(
            name: "SwiftDiffs",
            targets: ["SwiftDiffs"]
        ),
    ],
    targets: [
        .target(
            name: "SwiftDiffs"
        ),
        .testTarget(
            name: "SwiftDiffsTests",
            dependencies: ["SwiftDiffs"]
        ),
    ]
)
