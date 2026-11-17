// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "BatteryHealthCore",
    platforms: [.macOS(.v26)],
    products: [.library(name: "BatteryHealthCore", targets: ["BatteryHealthCore"])],
    targets: [
        .target(name: "BatteryHealthCore"),
        .testTarget(name: "BatteryHealthCoreTests", dependencies: ["BatteryHealthCore"]),
    ]
)
