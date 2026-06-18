// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "TaskScope",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "TaskScope", targets: ["TaskScope"])
    ],
    targets: [
        .executableTarget(name: "TaskScope")
    ]
)
