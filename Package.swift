// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CleanerMac",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "CleanerCore", targets: ["CleanerCore"]),
        .library(name: "CleanerSystem", targets: ["CleanerSystem"]),
        .library(name: "CleanerPreview", targets: ["CleanerPreview"]),
        .library(name: "CleanerUI", targets: ["CleanerUI"]),
        .executable(name: "CleanerApp", targets: ["CleanerApp"]),
    ],
    targets: [
        .target(
            name: "CleanerCore",
            dependencies: [],
            path: "Sources/CleanerCore"
        ),
        .target(
            name: "CleanerSystem",
            dependencies: ["CleanerCore"],
            path: "Sources/CleanerSystem"
        ),
        .target(
            name: "CleanerPreview",
            dependencies: ["CleanerCore"],
            path: "Sources/CleanerPreview"
        ),
        .target(
            name: "CleanerUI",
            dependencies: ["CleanerCore", "CleanerPreview"],
            path: "Sources/CleanerUI",
            resources: [
                .process("Resources")
            ]
        ),
        .executableTarget(
            name: "CleanerApp",
            dependencies: [
                "CleanerCore",
                "CleanerSystem",
                "CleanerPreview",
                "CleanerUI",
            ],
            path: "Sources/CleanerApp"
        ),
        .testTarget(
            name: "CleanerCoreTests",
            dependencies: ["CleanerCore"],
            path: "Tests/CleanerCoreTests"
        ),
        .testTarget(
            name: "CleanerSystemTests",
            dependencies: ["CleanerCore", "CleanerSystem"],
            path: "Tests/CleanerSystemTests"
        ),
        .testTarget(
            name: "CleanerPreviewTests",
            dependencies: ["CleanerCore", "CleanerPreview"],
            path: "Tests/CleanerPreviewTests"
        ),
        .testTarget(
            name: "CleanerUITests",
            dependencies: ["CleanerCore", "CleanerPreview", "CleanerUI"],
            path: "Tests/CleanerUITests"
        ),
    ]
)

