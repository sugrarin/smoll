// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "smoll",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "smoll", path: "Sources/smoll"),
        .testTarget(name: "smollTests", dependencies: ["smoll"], path: "Tests/smollTests")
    ]
)
