// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VigiaCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "VigiaCore", targets: ["VigiaCore"])
    ],
    targets: [
        .target(name: "VigiaCore"),
        .testTarget(name: "VigiaCoreTests", dependencies: ["VigiaCore"])
    ]
)
