// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "DeadCodeFinder",
    platforms: [
        .macOS(.v12)
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"), // Loosened version for better compatibility
        
        // --- THIS IS THE FIX ---
        // We are changing `from: "1.0.0"` to `branch: "main"` because the repository does not use version tags.
        .package(url: "https://github.com/swiftlang/indexstore-db.git", branch: "main")
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