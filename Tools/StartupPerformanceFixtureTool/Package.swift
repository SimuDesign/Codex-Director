// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "StartupPerformanceFixtureTool",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(name: "CodexDirector", path: "../..")
    ],
    targets: [
        .executableTarget(
            name: "StartupPerformanceFixtureTool",
            dependencies: [.product(name: "DirectorCore", package: "CodexDirector"),
                           .product(name: "DirectorUI", package: "CodexDirector")]
        )
    ]
)
