// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SwiftTermWrapper",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .visionOS(.v1)
    ],
    products: [
        .library(
            name: "SwiftTermWrapper",
            targets: ["SwiftTermWrapper"]
        ),
    ],
    dependencies: [
        .package(path: "../SwiftTerm")
    ],
    targets: [
        .target(
            name: "SwiftTermWrapper",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ]
        ),
    ]
)
