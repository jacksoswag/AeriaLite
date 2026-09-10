// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "aerialite",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(name: "aerialite", path: "src/aerialite"),
        .testTarget(name: "AeriaLiteTests", dependencies: ["aerialite"], path: "tests/unit"),
    ]
)
