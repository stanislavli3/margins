// swift-tools-version: 5.9
// Fallback: if the Xcode project ever refuses to open, run `swift run` in this folder.
import PackageDescription

let package = Package(
    name: "Margins",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Margins", path: "Margins", exclude: ["Assets.xcassets"])
    ]
)
