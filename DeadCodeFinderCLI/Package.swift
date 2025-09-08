// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "DeadCodeFinder",
    platforms: [
        .macOS(.v12)
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-syntax.git", from: "600.0.0-beta.1")
    ],
    targets: [
        .executableTarget(
            name: "DeadCodeFinder", // SPM will look for files in Sources/DeadCodeFinder/
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ]
            // The incorrect 'path:' parameter has been removed.
        ),
    ]
)
