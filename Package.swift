// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "CodexDirector",
    defaultLocalization: "en",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "DirectorCore", targets: ["DirectorCore"]),
        .library(name: "DirectorUI", targets: ["DirectorUI"]),
        .executable(name: "CodexDirectorApp", targets: ["CodexDirectorApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20")
    ],
    targets: [
        .target(
            name: "DirectorCore",
            dependencies: [
                .product(name: "ZIPFoundation", package: "ZIPFoundation")
            ]
        ),
        .target(
            name: "DirectorUI",
            dependencies: ["DirectorCore"],
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "CodexDirectorApp",
            dependencies: ["DirectorCore", "DirectorUI"]
        ),
        .testTarget(name: "DirectorCoreTests", dependencies: ["DirectorCore"]),
        .testTarget(name: "DirectorUITests", dependencies: ["DirectorUI", "DirectorCore"])
    ]
)
