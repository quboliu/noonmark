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
            name: "NoonmarkAIProviderLiveSmoke",
            targets: ["NoonmarkAIProviderLiveSmoke"]
        ),
        .executable(
            name: "NoonmarkDMGInstallHarness",
            targets: ["NoonmarkDMGInstallHarness"]
        ),
        .executable(
            name: "NoonmarkWindowProbe",
            targets: ["NoonmarkWindowProbe"]
        ),
        .library(name: "NoonmarkCore", targets: ["NoonmarkCore"]),
        .library(name: "NoonmarkDayContext", targets: ["NoonmarkDayContext"]),
        .library(name: "NoonmarkMacRuntime", targets: ["NoonmarkMacRuntime"]),
        .library(name: "NoonmarkDemoSupport", targets: ["NoonmarkDemoSupport"]),
        .library(name: "NoonmarkAI", targets: ["NoonmarkAI"]),
        .library(name: "NoonmarkZhulong", targets: ["NoonmarkZhulong"]),
        .library(name: "NoonmarkZhulongAI", targets: ["NoonmarkZhulongAI"]),
        .library(name: "NoonmarkMacUIContract", targets: ["NoonmarkMacUIContract"]),
        .library(name: "NoonmarkDiagnostics", targets: ["NoonmarkDiagnostics"]),
        .library(name: "NoonmarkStorage", targets: ["NoonmarkStorage"]),
        .library(name: "NoonmarkSync", targets: ["NoonmarkSync"])
    ],
    targets: [
        .executableTarget(
            name: "NoonmarkMacApp",
            dependencies: [
                "NoonmarkCore", "NoonmarkDayContext", "NoonmarkMacRuntime", "NoonmarkAI", "NoonmarkZhulong", "NoonmarkZhulongAI", "NoonmarkMacUIContract",
                "NoonmarkMacE2ESupport", "NoonmarkDemoSupport", "NoonmarkDiagnostics", "NoonmarkStorage", "NoonmarkSync"
            ],
            path: "App/NoonmarkMacApp",
            exclude: ["Resources"],
            linkerSettings: [
                .linkedFramework("Carbon")
            ]
        ),
        .executableTarget(
            name: "NoonmarkDMGInstallHarness",
            dependencies: [
                "NoonmarkDiagnostics",
                "NoonmarkMacE2ESupport",
                "NoonmarkMacRuntime"
            ],
            path: "Tools/NoonmarkDMGInstallHarness"
        ),
        .executableTarget(
            name: "NoonmarkWindowProbe",
            dependencies: ["NoonmarkMacE2ESupport"],
            path: "Tools/NoonmarkWindowProbe"
        ),
        .executableTarget(
            name: "NoonmarkAIProviderLiveSmoke",
            dependencies: [
                "NoonmarkAI",
                "NoonmarkCore",
                "NoonmarkZhulong",
                "NoonmarkZhulongAI"
            ],
            path: "Tools/NoonmarkAIProviderLiveSmoke"
        ),
        .target(name: "NoonmarkCore"),
        .target(
            name: "NoonmarkDayContext",
            dependencies: ["NoonmarkCore"]
        ),
        .target(
            name: "NoonmarkMacRuntime",
            dependencies: [
                "NoonmarkCore", "NoonmarkDayContext", "NoonmarkDiagnostics"
            ]
        ),
        .target(
            name: "NoonmarkDemoSupport",
            dependencies: ["NoonmarkCore"]
        ),
        .target(
            name: "NoonmarkAI",
            dependencies: ["NoonmarkCore"]
        ),
        .target(
            name: "NoonmarkZhulong",
            dependencies: ["NoonmarkCore", "NoonmarkDiagnostics"],
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
        .target(name: "NoonmarkDiagnostics"),
        .target(
            name: "NoonmarkStorage",
            dependencies: [
                "NoonmarkCore", "NoonmarkDiagnostics", "NoonmarkSync"
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .target(
            name: "NoonmarkSync",
            dependencies: ["NoonmarkCore", "NoonmarkDiagnostics"],
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
            dependencies: ["NoonmarkDiagnostics", "NoonmarkZhulong"]
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
            name: "NoonmarkDMGInstallHarnessTests",
            dependencies: ["NoonmarkDMGInstallHarness"],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .testTarget(
            name: "NoonmarkDemoSupportTests",
            dependencies: ["NoonmarkDemoSupport", "NoonmarkCore"]
        ),
        .testTarget(
            name: "NoonmarkDiagnosticsTests",
            dependencies: ["NoonmarkDiagnostics"]
        ),
        .testTarget(
            name: "NoonmarkStorageTests",
            dependencies: [
                "NoonmarkDiagnostics", "NoonmarkStorage", "NoonmarkSync"
            ]
        ),
        .testTarget(
            name: "NoonmarkSyncTests",
            dependencies: [
                "NoonmarkCore", "NoonmarkDiagnostics", "NoonmarkSync"
            ]
        ),
        .testTarget(
            name: "NoonmarkSimulationTests",
            dependencies: ["NoonmarkCore"]
        )
    ]
)
