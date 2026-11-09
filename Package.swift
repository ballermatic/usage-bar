// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "usage-bar",
    platforms: [.macOS(.v13)],
    targets: [.executableTarget(name: "usage-bar", path: "Sources/usage-bar")]
)
