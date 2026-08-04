// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "kino",
    platforms: [.macOS(.v14)],
    targets: [.executableTarget(name: "kino", path: "src/kino")]
)
