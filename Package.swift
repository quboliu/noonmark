// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Noonmark",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "SuntraceMacApp", targets: ["SuntraceMacApp"]),
        .library(name: "SuntraceCore", targets: ["SuntraceCore"]),
        .library(name: "SuntraceAI", targets: ["SuntraceAI"]),
        .library(name: "SuntraceMacUIContract", targets: ["SuntraceMacUIContract"]),
        .library(name: "SuntraceStorage", targets: ["SuntraceStorage"]),
        .library(name: "SuntraceSync", targets: ["SuntraceSync"])
    ],
    targets: [
        .executableTarget(
            name: "SuntraceMacApp",
            dependencies: ["SuntraceCore", "SuntraceAI", "SuntraceMacUIContract", "SuntraceStorage"],
            path: "App/SuntraceMacApp"
        ),
        .target(name: "SuntraceCore"),
        .target(
            name: "SuntraceAI",
            dependencies: ["SuntraceCore"]
        ),
        .target(name: "SuntraceMacUIContract"),
        .target(
            name: "SuntraceStorage",
            dependencies: ["SuntraceCore", "SuntraceSync"],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .target(
            name: "SuntraceSync",
            dependencies: ["SuntraceCore"]
        ),
        .testTarget(
            name: "SuntraceCoreTests",
            dependencies: ["SuntraceCore"]
        ),
        .testTarget(
            name: "SuntraceAITests",
            dependencies: ["SuntraceAI", "SuntraceCore"]
        ),
        .testTarget(
            name: "SuntraceMacUIContractTests",
            dependencies: ["SuntraceMacUIContract"]
        ),
        .testTarget(
            name: "SuntraceStorageTests",
            dependencies: ["SuntraceStorage", "SuntraceSync"]
        ),
        .testTarget(
            name: "SuntraceSyncTests",
            dependencies: ["SuntraceSync", "SuntraceCore"]
        ),
        .testTarget(
            name: "SuntraceSimulationTests",
            dependencies: ["SuntraceCore"]
        )
    ]
)
