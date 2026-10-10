// swift-tools-version: 6.0
// earshot-tts: Kokoro speech for Earshot. scripts/build-tts.sh builds it.
import PackageDescription

let package = Package(
    name: "earshot-tts",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7"),
    ],
    targets: [
        .executableTarget(
            name: "earshot-tts",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
