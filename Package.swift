// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OpenContexts",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    products: [.library(name: "OpenContextsApp", targets: ["OpenContextsApp"])],
    dependencies: [.package(url: "https://github.com/x-sheep/swift-property-based", from: "2.0.1")],
    targets: [
        .target(name: "OpenContextsCore"),
        .target(
            name: "OpenContextsApp",
            dependencies: ["OpenContextsCore"],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "OpenContextsCoreTests",
            dependencies: ["OpenContextsCore", .product(name: "PropertyBased", package: "swift-property-based")]
        ),
        .testTarget(name: "OpenContextsAppTests", dependencies: ["OpenContextsApp"])
    ]
)
