// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OpenContexts",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "OpenContexts", targets: ["OpenContexts"])],
    targets: [
        .target(name: "OpenContextsCore"),
        .target(
            name: "OpenContextsApp",
            dependencies: ["OpenContextsCore"],
            resources: [.process("Resources")]
        ),
        .executableTarget(name: "OpenContexts", dependencies: ["OpenContextsApp"]),
        .testTarget(name: "OpenContextsCoreTests", dependencies: ["OpenContextsCore"]),
        .testTarget(name: "OpenContextsAppTests", dependencies: ["OpenContextsApp"])
    ]
)
