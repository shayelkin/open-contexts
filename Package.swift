// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OpenContexts",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "OpenContexts", targets: ["OpenContexts"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")],
    targets: [
        .target(name: "OpenContextsCore"),
        .target(
            name: "OpenContextsApp",
            dependencies: ["OpenContextsCore", .product(name: "Sparkle", package: "Sparkle")],
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "OpenContexts",
            dependencies: ["OpenContextsApp"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "OpenContextsCoreTests", dependencies: ["OpenContextsCore"]),
        .testTarget(name: "OpenContextsAppTests", dependencies: ["OpenContextsApp"])
    ]
)
