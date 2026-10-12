// swift-tools-version: 6.0
import PackageDescription

// The HomeKit helper in Helper/ is a Mac Catalyst app, which SwiftPM can't
// build; scripts/bundle.sh compiles it together with Sources/EcobeeKit.
let package = Package(
    name: "EcobeeBar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "EcobeeBar", targets: ["EcobeeBar"]),
    ],
    targets: [
        .target(name: "EcobeeKit"),
        .executableTarget(name: "EcobeeBar", dependencies: ["EcobeeKit"]),
        .testTarget(name: "EcobeeKitTests", dependencies: ["EcobeeKit"]),
    ]
)
