// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LiveWallpaperCore",
    platforms: [.macOS(.v26)],
    products: [.library(name: "LiveWallpaperCore", targets: ["LiveWallpaperCore"])],
    targets: [
        .target(name: "LiveWallpaperCore"),
        .testTarget(name: "LiveWallpaperCoreTests", dependencies: ["LiveWallpaperCore"]),
    ]
)
