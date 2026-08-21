// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CodexTrafficLightMXP",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "CodexTrafficLightCore", targets: ["CodexTrafficLightCore"]),
        .executable(name: "CodexTrafficLightApp", targets: ["CodexTrafficLightApp"]),
        .executable(name: "codex-light-mxp", targets: ["codex-light-mxp"]),
        .executable(name: "codex-light-hook-mxp", targets: ["codex-light-hook-mxp"]),
        .executable(name: "codex-light-mxp-tests", targets: ["codex-light-mxp-tests"])
    ],
    targets: [
        .target(name: "CodexTrafficLightCore"),
        .executableTarget(
            name: "CodexTrafficLightApp",
            dependencies: ["CodexTrafficLightCore"],
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "codex-light-mxp",
            dependencies: ["CodexTrafficLightCore"]
        ),
        .executableTarget(
            name: "codex-light-hook-mxp",
            dependencies: ["CodexTrafficLightCore"]
        ),
        .executableTarget(
            name: "codex-light-mxp-tests",
            dependencies: ["CodexTrafficLightCore"]
        )
    ]
)
