// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AudioMixerCore",
    platforms: [.macOS(.v26)],
    products: [.library(name: "AudioMixerCore", targets: ["AudioMixerCore"])],
    targets: [
        .target(name: "AudioMixerCore"),
        .testTarget(name: "AudioMixerCoreTests", dependencies: ["AudioMixerCore"]),
    ]
)
