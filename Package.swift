// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Suntrace",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "SuntraceCore", targets: ["SuntraceCore"]),
        .library(name: "SuntraceAI", targets: ["SuntraceAI"]),
        .library(name: "SuntraceMacUIContract", targets: ["SuntraceMacUIContract"]),
        .library(name: "SuntraceStorage", targets: ["SuntraceStorage"])
    ],
    targets: [
        .target(name: "SuntraceCore"),
        .target(
            name: "SuntraceAI",
            dependencies: ["SuntraceCore"]
        ),
        .target(name: "SuntraceMacUIContract"),
        .target(
            name: "SuntraceStorage",
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
        )
    ]
)
