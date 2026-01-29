// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AutomergeWrapper",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .visionOS(.v1)
    ],
    products: [
        .library(
            name: "AutomergeWrapper",
            targets: ["AutomergeWrapper"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/automerge/automerge-swift.git", from: "0.7.0")
    ],
    targets: [
        .target(
            name: "AutomergeWrapper",
            dependencies: [
                .product(name: "Automerge", package: "automerge-swift")
            ]
        ),
    ]
)
