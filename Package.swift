// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "JustWisper",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "JustWisper", targets: ["JustWisper"])],
    dependencies: [.package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7", traits: [])],
    targets: [.executableTarget(name: "JustWisper", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]), .testTarget(name: "JustWisperTests", dependencies: ["JustWisper"])],
    swiftLanguageModes: [.v5]
)
