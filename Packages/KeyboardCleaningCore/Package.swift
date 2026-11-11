// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "KeyboardCleaningCore",
    platforms: [.macOS(.v26)],
    products: [.library(name: "KeyboardCleaningCore", targets: ["KeyboardCleaningCore"])],
    targets: [
        .target(name: "KeyboardCleaningCore"),
        .testTarget(name: "KeyboardCleaningCoreTests", dependencies: ["KeyboardCleaningCore"]),
    ]
)
