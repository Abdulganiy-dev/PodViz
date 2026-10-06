// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "PodViz",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PodViz", targets: ["PodViz"]),
        .executable(name: "pvreplay", targets: ["pvreplay"]),
    ],
    targets: [
        // Log parsing + live session model. No UI, so it can be replayed from the CLI.
        .target(name: "PodVizCore"),
        // The menu bar app.
        .executableTarget(name: "PodViz", dependencies: ["PodVizCore"]),
        // Feeds a saved `pod install --verbose` log through the parser and prints the result.
        .executableTarget(name: "pvreplay", dependencies: ["PodVizCore"]),
    ],
    swiftLanguageModes: [.v5]
)
