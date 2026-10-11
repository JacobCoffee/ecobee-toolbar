// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EcobeeBar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "EcobeeBar", targets: ["EcobeeBar"]),
        .executable(name: "hapctl", targets: ["hapctl"]),
        .library(name: "HAPKit", targets: ["HAPKit"]),
        .library(name: "EcobeeKit", targets: ["EcobeeKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/attaswift/BigInt.git", from: "5.4.0"),
    ],
    targets: [
        .target(name: "HAPKit", dependencies: [.product(name: "BigInt", package: "BigInt")]),
        .target(name: "EcobeeKit", dependencies: ["HAPKit"]),
        .executableTarget(name: "hapctl", dependencies: ["HAPKit", "EcobeeKit"]),
        .executableTarget(name: "EcobeeBar", dependencies: ["EcobeeKit"]),
        .testTarget(name: "HAPKitTests", dependencies: ["HAPKit"]),
    ]
)
