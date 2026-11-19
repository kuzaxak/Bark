// Licensed under GPL-3.0. See LICENSE.
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NookWeb",
    platforms: [.macOS("15.5")],
    products: [
        .library(name: "NookWeb", targets: ["NookWeb"]),
    ],
    dependencies: [
        .package(path: "../NookTabsCore"),
        .package(path: "../NookSettings"),
        .package(path: "../NookBlocker"),
        .package(path: "../NookTweaks"),
    ],
    targets: [
        .target(
            name: "NookWeb",
            dependencies: [
                .product(name: "NookTabsCore", package: "NookTabsCore"),
                .product(name: "NookSettings", package: "NookSettings"),
                .product(name: "NookBlocker", package: "NookBlocker"),
                .product(name: "NookTweaks", package: "NookTweaks"),
            ],
            resources: [.copy("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "NookWebTests",
            dependencies: [
                "NookWeb",
                .product(name: "NookTabsCore", package: "NookTabsCore"),
                .product(name: "NookSettings", package: "NookSettings"),
                .product(name: "NookBlocker", package: "NookBlocker"),
                .product(name: "NookTweaks", package: "NookTweaks"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
