// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PaperShelf",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "PaperShelfCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "PaperShelf",
            dependencies: ["PaperShelfCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "PaperShelfMCP",
            dependencies: ["PaperShelfCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "PaperShelfCoreTests",
            dependencies: ["PaperShelfCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The app target had no tests at all, which is how a spend recorder that defaulted
        // to nil went unnoticed while every call in the app recorded nothing.
        .testTarget(
            name: "PaperShelfAppTests",
            dependencies: ["PaperShelf", "PaperShelfCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
