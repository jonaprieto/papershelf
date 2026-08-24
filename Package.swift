// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PDFHammer",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "PDFHammerCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "PDFHammer",
            dependencies: ["PDFHammerCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "PDFHammerCoreTests",
            dependencies: ["PDFHammerCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
