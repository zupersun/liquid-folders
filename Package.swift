// swift-tools-version:5.9
// Build the app: ./build.sh   (or just the agent: swift build -c release; .build/release/liquidfolder run)
import PackageDescription

let package = Package(
    name: "LiquidFolder",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(name: "liquidfolder", path: "src"),
    ]
)
