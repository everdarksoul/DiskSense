// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DiskSense",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "DiskSense",
            path: "Sources/DiskSense"
        ),
        .testTarget(name: "DiskSenseTests", dependencies: ["DiskSense"])
    ],
    swiftLanguageModes: [.v5]
)
