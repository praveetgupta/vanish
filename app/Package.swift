// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Vanish",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Vanish",
            path: "Sources/Vanish"
        )
    ]
)
