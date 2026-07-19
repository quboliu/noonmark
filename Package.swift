// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Noonmark",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "NoonmarkMacApp", targets: ["NoonmarkMacApp"]),
        .executable(
            name: "NoonmarkDMGInstallHarness",
            targets: ["NoonmarkDMGInstallHarness"]
        ),
        .library(name: "NoonmarkCore", targets: ["NoonmarkCore"]),
        .library(name: "NoonmarkDayContext", targets: ["NoonmarkDayContext"]),
        .library(name: "NoonmarkMacRuntime", targets: ["NoonmarkMacRuntime"]),
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
                "NoonmarkCore", "NoonmarkDayContext", "NoonmarkMacRuntime", "NoonmarkAI", "NoonmarkZhulong", "NoonmarkZhulongAI", "NoonmarkMacUIContract",
                "NoonmarkMacE2ESupport", "NoonmarkStorage", "NoonmarkSync"
            ],
            path: "App/NoonmarkMacApp",
            exclude: ["Resources"]
        ),
        .executableTarget(
            name: "NoonmarkDMGInstallHarness",
            path: "Tools/NoonmarkDMGInstallHarness"
        ),
        .target(name: "NoonmarkCore"),
        .target(
            name: "NoonmarkDayContext",
            dependencies: ["NoonmarkCore"]
        ),
        .target(
            name: "NoonmarkMacRuntime",
            dependencies: ["NoonmarkCore", "NoonmarkDayContext"]
        ),
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
        .target(name: "NoonmarkMacE2ESupport"),
        .target(
            name: "NoonmarkStorage",
            dependencies: ["NoonmarkCore", "NoonmarkSync"],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .target(
            name: "NoonmarkSync",
            dependencies: ["NoonmarkCore"],
            linkerSettings: [
                .linkedFramework("CloudKit"),
                .linkedFramework("Security")
            ]
        ),
        .testTarget(
            name: "NoonmarkCoreTests",
            dependencies: ["NoonmarkCore"]
        ),
        .testTarget(
            name: "NoonmarkDayContextTests",
            dependencies: ["NoonmarkDayContext", "NoonmarkCore"]
        ),
        .testTarget(
            name: "NoonmarkMacRuntimeTests",
            dependencies: [
                "NoonmarkMacRuntime",
                "NoonmarkCore",
                "NoonmarkDayContext",
                "NoonmarkStorage",
                "NoonmarkSync"
            ]
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
            name: "NoonmarkMacE2ESupportTests",
            dependencies: ["NoonmarkMacE2ESupport"]
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
