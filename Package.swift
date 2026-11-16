// swift-tools-version:5.9
import PackageDescription

// The L16Studio macOS app as a plain SwiftPM executable, so it builds with
// just the Swift toolchain (no Xcode project). `scripts/build-app.sh` wraps
// the built binary into L16Studio.app.
let package = Package(
    name: "L16Studio",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "LRIKit")
    ],
    targets: [
        .executableTarget(
            name: "L16Studio",
            dependencies: [.product(name: "LRIKit", package: "LRIKit")],
            path: "L16Studio/Sources"
        )
    ]
)
