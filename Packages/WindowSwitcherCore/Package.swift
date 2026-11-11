// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "WindowSwitcherCore",
    platforms: [.macOS(.v26)],
    products: [.library(name: "WindowSwitcherCore", targets: ["WindowSwitcherCore"])],
    targets: [
        .target(name: "WindowSwitcherCore"),
        .testTarget(name: "WindowSwitcherCoreTests", dependencies: ["WindowSwitcherCore"]),
    ]
)
