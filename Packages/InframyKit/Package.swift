// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "InframyKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "InframyKit", targets: ["InframyKit"]),
        .executable(name: "inframy-cli", targets: ["inframy-cli"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(name: "InframyKit"),
        .executableTarget(
            name: "inframy-cli",
            dependencies: [
                "InframyKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "InframyKitTests",
            dependencies: ["InframyKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
