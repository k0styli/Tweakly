// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "UninstallerCore",
    platforms: [.macOS(.v26)],
    products: [.library(name: "UninstallerCore", targets: ["UninstallerCore"])],
    targets: [
        .target(name: "UninstallerCore"),
        .testTarget(name: "UninstallerCoreTests", dependencies: ["UninstallerCore"]),
    ]
)
