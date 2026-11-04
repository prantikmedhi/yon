// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Yon",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.7.0"),
    ],
    targets: [
        .executableTarget(
            name: "Yon",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Yon",
            // Sparkle is a dynamic framework; bundle.sh copies it to Contents/Frameworks next to the binary.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
    ]
)
