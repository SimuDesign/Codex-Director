// swift-tools-version: 6.3
import Foundation
import PackageDescription

// The interaction harness is an opt-in, local Release-equivalent build. The
// normal package graph does not compile the validation host or its driver.
let interactionPerformanceEnabled = ProcessInfo.processInfo.environment["DIRECTOR_INTERACTION_PERFORMANCE"] == "1"
let interactionPerformanceSettings: [SwiftSetting] = interactionPerformanceEnabled
    ? [.define("DIRECTOR_INTERACTION_PERFORMANCE")]
    : []

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
            resources: [.process("Resources")],
            swiftSettings: interactionPerformanceSettings
        ),
        .executableTarget(
            name: "CodexDirectorApp",
            dependencies: ["DirectorCore", "DirectorUI"]
        ),
        .testTarget(name: "DirectorCoreTests", dependencies: ["DirectorCore"]),
        .testTarget(
            name: "DirectorUITests",
            dependencies: ["DirectorUI", "DirectorCore"],
            swiftSettings: interactionPerformanceSettings
        )
    ]
)
