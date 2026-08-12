// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LimitIsland",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "LimitIsland", targets: ["LimitIsland"]),
        // Runs once per CLI hook event and exits. Kept dependency-free and tiny on
        // purpose: it is in the critical path of every tool call the user's agents
        // make, so it must start fast and never fail loudly.
        .executable(name: "limitisland-hook", targets: ["LimitIslandHook"])
    ],
    targets: [
        .executableTarget(
            name: "LimitIsland",
            resources: [.process("Resources")]
        ),
        .executableTarget(name: "LimitIslandHook"),
        .testTarget(
            name: "LimitIslandTests",
            dependencies: ["LimitIsland"]
        )
    ]
)
