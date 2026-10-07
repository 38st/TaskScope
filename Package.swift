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
    dependencies: [
        .package(
            url: "https://github.com/nalexn/ViewInspector.git",
            exact: "0.10.5"
        )
    ],
    targets: [
        .executableTarget(name: "TaskScope"),
        .testTarget(
            name: "TaskScopeTests",
            dependencies: [
                "TaskScope",
                .product(name: "ViewInspector", package: "ViewInspector")
            ]
        )
    ]
)
