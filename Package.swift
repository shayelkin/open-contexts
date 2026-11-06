// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OpenContexts",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    products: [.library(name: "OpenContextsApp", targets: ["OpenContextsApp"])],
    targets: [
        .target(name: "OpenContextsCore"),
        .target(
            name: "OpenContextsApp",
            dependencies: ["OpenContextsCore"],
            resources: [.process("Resources")]
        ),
        .testTarget(name: "OpenContextsCoreTests", dependencies: ["OpenContextsCore"]),
        .testTarget(name: "OpenContextsAppTests", dependencies: ["OpenContextsApp"])
    ]
)
