// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LanguageSwitchCore",
    platforms: [.macOS(.v26)],
    products: [.library(name: "LanguageSwitchCore", targets: ["LanguageSwitchCore"])],
    targets: [
        .target(name: "LanguageSwitchCore"),
        .testTarget(name: "LanguageSwitchCoreTests", dependencies: ["LanguageSwitchCore"]),
    ]
)
