// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Patch",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "Patch", targets: ["ScreenLeaf"])],
    targets: [
        .executableTarget(name: "ScreenLeaf"),
        .testTarget(name: "ScreenLeafTests", dependencies: ["ScreenLeaf"])
    ],
    swiftLanguageModes: [.v5]
)
