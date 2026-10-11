// swift-tools-version: 6.2
// EarshotKit: everything in Earshot for Mac that is not UI.
import PackageDescription

let package = Package(
    name: "EarshotKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "EarshotKit", targets: ["EarshotKit"]),
        .executable(name: "earshot-probe", targets: ["earshot-probe"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7"),
    ],
    targets: [
        .target(name: "EarshotKit", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]),
        .executableTarget(name: "earshot-probe", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]),
        .testTarget(name: "EarshotKitTests", dependencies: ["EarshotKit"]),
    ]
)
