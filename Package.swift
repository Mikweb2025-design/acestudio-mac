// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ACEStudio",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "ACEStudio",
            path: "Sources/ACEStudio",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
