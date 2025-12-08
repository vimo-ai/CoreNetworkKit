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
        .package(url: "https://github.com/vimo-ai/MLoggerKit.git", from: "0.0.1"),
        .package(url: "https://github.com/Alamofire/Alamofire.git", from: "5.8.0")
    ],
    targets: [
        .target(
            name: "CoreNetworkKit",
            dependencies: [
                "MLoggerKit",
                .product(name: "Alamofire", package: "Alamofire")
            ]),
        .testTarget(
            name: "CoreNetworkKitTests",
            dependencies: ["CoreNetworkKit"])
    ]
)