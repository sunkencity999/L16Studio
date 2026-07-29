// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LRIKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "LRIKit", targets: ["LRIKit"]),
        .executable(name: "lriprobe", targets: ["lriprobe"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.28.0")
    ],
    targets: [
        .target(
            name: "LRIKit",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf")
            ]
        ),
        .executableTarget(
            name: "lriprobe",
            dependencies: ["LRIKit"]
        ),
        .testTarget(
            name: "LRIKitTests",
            dependencies: ["LRIKit"]
        )
    ]
)
