// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LidClosed",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "LidClosed",
            path: "Sources",
            linkerSettings: [
                .linkedFramework("AppKit")
            ]
        ),
        .testTarget(
            name: "LidClosedTests",
            dependencies: ["LidClosed"],
            path: "Tests"
        )
    ]
)
