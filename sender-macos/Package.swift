// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "mactv",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "mactv",
            path: "Sources/mactv"
        )
    ]
)
