// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Pliw-Face",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "pliw-face",
            targets: ["PliwFace"]
        )
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "PliwFace",
            dependencies: [],
            path: "Sources/PliwFace"
        ),
        .testTarget(
            name: "PliwFaceTests",
            dependencies: ["PliwFace"],
            path: "Tests/PliwFaceTests"
        )
    ]
)
