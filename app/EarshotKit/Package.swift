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
        // Not used by this package. The app (app/project.yml) pins the same version of Sparkle, and
        // Xcode writes both pins into this package's Package.resolved. Listing it here keeps
        // `swift package resolve` and Xcode writing the same file, so the tree stays clean.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .target(name: "EarshotKit", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]),
        .executableTarget(name: "earshot-probe", dependencies: ["EarshotKit", .product(name: "FluidAudio", package: "FluidAudio")]),
        .testTarget(name: "EarshotKitTests", dependencies: ["EarshotKit"]),
    ]
)
