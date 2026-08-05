// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "aerialite",
    platforms: [.macOS(.v14)],
    targets: [.executableTarget(name: "aerialite", path: "src/aerialite")]
)
