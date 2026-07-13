// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Noonmark",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "NoonmarkMacApp", targets: ["NoonmarkMacApp"]),
        .library(name: "NoonmarkCore", targets: ["NoonmarkCore"]),
        .library(name: "NoonmarkAI", targets: ["NoonmarkAI"]),
        .library(name: "NoonmarkZhulong", targets: ["NoonmarkZhulong"]),
        .library(name: "NoonmarkZhulongAI", targets: ["NoonmarkZhulongAI"]),
        .library(name: "NoonmarkMacUIContract", targets: ["NoonmarkMacUIContract"]),
        .library(name: "NoonmarkStorage", targets: ["NoonmarkStorage"]),
        .library(name: "NoonmarkSync", targets: ["NoonmarkSync"])
    ],
    targets: [
        .executableTarget(
            name: "NoonmarkMacApp",
            dependencies: [
                "NoonmarkCore", "NoonmarkAI", "NoonmarkZhulong", "NoonmarkZhulongAI", "NoonmarkMacUIContract",
                "NoonmarkStorage", "NoonmarkSync"
            ],
            path: "App/NoonmarkMacApp",
            exclude: ["Resources"]
        ),
        .target(name: "NoonmarkCore"),
        .target(
            name: "NoonmarkAI",
            dependencies: ["NoonmarkCore"]
        ),
        .target(
            name: "NoonmarkZhulong",
            dependencies: ["NoonmarkCore"],
            linkerSettings: [
                .linkedFramework("Security")
            ]
        ),
        .target(
            name: "NoonmarkZhulongAI",
            dependencies: ["NoonmarkAI", "NoonmarkZhulong"]
        ),
        .target(name: "NoonmarkMacUIContract"),
        .target(
            name: "NoonmarkStorage",
            dependencies: ["NoonmarkCore", "NoonmarkSync"],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .target(
            name: "NoonmarkSync",
            dependencies: ["NoonmarkCore"]
        ),
        .testTarget(
            name: "NoonmarkCoreTests",
            dependencies: ["NoonmarkCore"]
        ),
        .testTarget(
            name: "NoonmarkAITests",
            dependencies: ["NoonmarkAI", "NoonmarkCore"]
        ),
        .testTarget(
            name: "NoonmarkZhulongTests",
            dependencies: ["NoonmarkZhulong"]
        ),
        .testTarget(
            name: "NoonmarkZhulongAITests",
            dependencies: ["NoonmarkZhulongAI", "NoonmarkAI", "NoonmarkZhulong"]
        ),
        .testTarget(
            name: "NoonmarkMacUIContractTests",
            dependencies: ["NoonmarkMacUIContract"]
        ),
        .testTarget(
            name: "NoonmarkStorageTests",
            dependencies: ["NoonmarkStorage", "NoonmarkSync"]
        ),
        .testTarget(
            name: "NoonmarkSyncTests",
            dependencies: ["NoonmarkSync", "NoonmarkCore"]
        ),
        .testTarget(
            name: "NoonmarkSimulationTests",
            dependencies: ["NoonmarkCore"]
        )
    ]
)
