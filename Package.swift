// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexSwap",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "SwapKit", targets: ["SwapKit"]),
        .executable(name: "swapd", targets: ["swapd"]),
        .executable(name: "CodexSwapApp", targets: ["CodexSwapApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.21.0"),
    ],
    targets: [
        .target(
            name: "SwapKit",
            dependencies: [
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
            ]
        ),
        .executableTarget(
            name: "swapd",
            dependencies: ["SwapKit"]
        ),
        .executableTarget(
            name: "CodexSwapApp",
            dependencies: ["SwapKit"]
        ),
        .testTarget(
            name: "SwapKitTests",
            dependencies: ["SwapKit"]
        ),
    ]
)
