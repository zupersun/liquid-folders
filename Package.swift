// swift-tools-version:5.9
// Build the app with ./build.sh
import PackageDescription

let package = Package(
    name: "LiquidFolder",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(name: "liquidfolder", path: "src"),
    ]
)
