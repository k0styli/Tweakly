// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FinderMenuCore",
    platforms: [.macOS(.v26)],
    products: [.library(name: "FinderMenuCore", targets: ["FinderMenuCore"])],
    targets: [
        .target(name: "FinderMenuCore"),
        .testTarget(name: "FinderMenuCoreTests", dependencies: ["FinderMenuCore"]),
    ]
)
