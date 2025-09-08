// swift-tools-version: 5.10
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "DeadCodeFinder",
    platforms: [
        .macOS(.v12)
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/swiftlang/indexstore-db.git", branch: "release/6.1.1")
    ],
    targets: [
        .executableTarget(
            name: "DeadCodeFinder",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "IndexStoreDB", package: "indexstore-db"),
            ]
        ),
    ]
)