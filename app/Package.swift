// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "VintedManager",
    // Liquid Glass (glassEffect, glass toolbars) needs macOS 26.
    platforms: [.macOS(.v26)],
    targets: [
        // Reads and updates the Markdown repository. No UI code.
        .target(name: "VintedCore"),
        .executableTarget(name: "VintedManager", dependencies: ["VintedCore"]),
        .executableTarget(name: "VintedPhotoConverter"),
        .testTarget(name: "VintedCoreTests", dependencies: ["VintedCore"]),
    ]
)
