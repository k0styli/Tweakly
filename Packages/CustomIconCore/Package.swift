// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CustomIconCore",
    platforms: [.macOS(.v26)],
    products: [.library(name: "CustomIconCore", targets: ["CustomIconCore"])],
    targets: [
        .target(name: "CustomIconCore"),
        .testTarget(name: "CustomIconCoreTests", dependencies: ["CustomIconCore"]),
    ]
)
