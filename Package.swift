// swift-tools-version:5.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "AudioAlignment",
    platforms: [.macOS(.v11), .iOS(.v13), .tvOS(.v13), .watchOS(.v6)],
    products: [
        .library(
            name: "AudioAlignment",
            targets: ["AudioAlignment"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "AudioAlignment",
            dependencies: []),
        .target(
            name: "Fixtures",
            dependencies: [],
            resources: [
                .copy("reference.m4a"),
                .copy("sample.m4a")
            ]),
        .target(
            name: "AudioAlignmentExecutableForProfile",
            dependencies: ["AudioAlignment", "Fixtures"]),
        .testTarget(
            name: "AudioAlignmentTests",
            dependencies: ["AudioAlignment", "Fixtures"]),
    ]
)
