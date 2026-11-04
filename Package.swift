// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Yon",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Yon", path: "Sources/Yon")
    ]
)
