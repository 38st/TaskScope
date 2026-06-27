// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "TaskScope",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "TaskScope", targets: ["TaskScope"])
    ],
    targets: [
        .executableTarget(name: "TaskScope"),
        .testTarget(
            name: "TaskScopeTests",
            dependencies: ["TaskScope"]
        )
    ]
)
