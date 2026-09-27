// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MornRunner",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "MornRunner", targets: ["MornRunner"])],
    targets: [
        .executableTarget(name: "MornRunner"),
        .testTarget(name: "MornRunnerTests", dependencies: ["MornRunner"])
    ],
    swiftLanguageModes: [.v5]
)
