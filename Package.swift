// swift-tools-version: 5.8
import PackageDescription

let package = Package(
    name: "CoreNetworkKit",
    platforms: [
        .macOS(.v12),
        .iOS(.v15),
        .tvOS(.v15)
    ],
    products: [
        .library(
            name: "CoreNetworkKit",
            targets: ["CoreNetworkKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/vimo-ai/MLoggerKit.git", from: "1.0.0")
    ],
    targets: [
        .target(
            name: "CoreNetworkKit",
            dependencies: ["MLoggerKit"])
    ]
)