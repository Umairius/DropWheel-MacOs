// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DropWheel",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "DropWheel", path: "Sources/DropWheel"),
    ]
)
