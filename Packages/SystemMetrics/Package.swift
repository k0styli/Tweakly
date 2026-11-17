// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SystemMetrics",
    platforms: [.macOS(.v26)],
    products: [.library(name: "SystemMetrics", targets: ["SystemMetrics"])],
    dependencies: [.package(path: "../BatteryHealthCore")],
    targets: [
        .target(
            name: "SystemMetrics",
            dependencies: ["BatteryHealthCore"],
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("SystemConfiguration")]
        ),
        .testTarget(name: "SystemMetricsTests", dependencies: ["SystemMetrics"]),
    ]
)
