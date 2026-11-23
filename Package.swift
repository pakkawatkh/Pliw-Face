// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "tiffy-face",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "tiffy-face",
            targets: ["TiffyFace"]
        )
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "TiffyFace",
            dependencies: [],
            path: "Sources/TiffyFace"
        ),
        .testTarget(
            name: "TiffyFaceTests",
            dependencies: ["TiffyFace"],
            path: "Tests/TiffyFaceTests"
        )
    ]
)
