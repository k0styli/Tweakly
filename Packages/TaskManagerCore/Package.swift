// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TaskManagerCore",
    platforms: [.macOS(.v26)],
    products: [.library(name: "TaskManagerCore", targets: ["TaskManagerCore"])],
    targets: [
        .target(name: "TaskManagerCore"),
        .testTarget(name: "TaskManagerCoreTests", dependencies: ["TaskManagerCore"]),
    ]
)
