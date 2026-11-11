// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FinderCutCore",
    platforms: [.macOS(.v26)],
    products: [.library(name: "FinderCutCore", targets: ["FinderCutCore"])],
    targets: [
        .target(name: "FinderCutCore"),
        .testTarget(name: "FinderCutCoreTests", dependencies: ["FinderCutCore"]),
    ]
)
