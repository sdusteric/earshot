// swift-tools-version: 6.0
// kobi-tts: Kokoro speech for Kobi. scripts/build-tts.sh builds it.
import PackageDescription

let package = Package(
    name: "kobi-tts",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7"),
    ],
    targets: [
        .executableTarget(
            name: "kobi-tts",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
