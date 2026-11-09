// Licensed under GPL-3.0. See LICENSE.
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BarkEngine",
    platforms: [.macOS("15.5")],
    products: [
        .library(name: "BarkEngine", targets: ["BarkEngine"]),
    ],
    targets: [
        .binaryTarget(name: "BarkEngine", path: "BarkEngine.xcframework"),
    ]
)
