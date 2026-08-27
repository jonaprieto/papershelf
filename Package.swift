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
        .executableTarget(
            name: "PDFHammerMCP",
            dependencies: ["PDFHammerCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "PDFHammerCoreTests",
            dependencies: ["PDFHammerCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The app target had no tests at all, which is how a spend recorder that defaulted
        // to nil went unnoticed while every call in the app recorded nothing.
        .testTarget(
            name: "PDFHammerAppTests",
            dependencies: ["PDFHammer", "PDFHammerCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
