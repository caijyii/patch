// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Patch",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "Patch", targets: ["Patch"])],
    targets: [
        .executableTarget(name: "Patch"),
        .testTarget(name: "PatchTests", dependencies: ["Patch"])
    ],
    swiftLanguageModes: [.v5]
)
