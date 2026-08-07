// swift-tools-version:6.0
import PackageDescription

// SwiftPM rather than an Xcode project: this machine has Command Line Tools only,
// so `xcodebuild` is unavailable. build.sh assembles the .app bundle around the
// executable this produces.
let package = Package(
    name: "Headroom",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Headroom",
            path: "Sources/Headroom"
        )
    ]
)
