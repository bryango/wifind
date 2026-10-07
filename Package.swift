// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "wifind",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "WifindKit"),
        .executableTarget(name: "wifind", dependencies: ["WifindKit"]),
        .testTarget(name: "WifindKitTests", dependencies: ["WifindKit"]),
    ]
)
