// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MouseCore",
    platforms: [.macOS(.v26)],
    products: [.library(name: "MouseCore", targets: ["MouseCore"])],
    targets: [
        .target(name: "MouseCore"),
        .testTarget(name: "MouseCoreTests", dependencies: ["MouseCore"]),
    ]
)
