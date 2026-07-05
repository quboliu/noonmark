// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Suntrace",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "SuntraceCore", targets: ["SuntraceCore"]),
        .library(name: "SuntraceStorage", targets: ["SuntraceStorage"])
    ],
    targets: [
        .target(name: "SuntraceCore"),
        .target(
            name: "SuntraceStorage",
            dependencies: ["SuntraceCore"]
        ),
        .testTarget(
            name: "SuntraceCoreTests",
            dependencies: ["SuntraceCore"]
        )
    ]
)

