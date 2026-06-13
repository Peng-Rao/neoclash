// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "NeoClash",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .library(name: "NeoClashCore", targets: ["NeoClashCore"]),
        .executable(name: "NeoClash", targets: ["NeoClashApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.0.0")
    ],
    targets: [
        .target(
            name: "NeoClashCore",
            dependencies: [
                .product(name: "Yams", package: "Yams")
            ],
            path: "NeoClash",
            exclude: [
                "App",
                "Views",
                "Resources"
            ],
            sources: [
                "Core",
                "Helpers",
                "Models",
                "Services",
                "Stores"
            ]
        ),
        .executableTarget(
            name: "NeoClashApp",
            dependencies: ["NeoClashCore"],
            path: "NeoClash",
            exclude: [
                "Core",
                "Helpers",
                "Models",
                "App/Info.plist",
                "Services",
                "Stores"
            ],
            sources: [
                "App",
                "Views"
            ],
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "NeoClashCoreTests",
            dependencies: ["NeoClashCore"],
            path: "Tests/NeoClashCoreTests"
        )
    ]
)
