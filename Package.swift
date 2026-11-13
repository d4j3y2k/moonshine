// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Moonshine",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Moonshine", targets: ["Moonshine"]),
               .executable(name: "moonshine-check", targets: ["MoonshineCheck"])],
    targets: [
        .target(name: "MoonshineCore"),
        .target(name: "MoonshinePlatform", dependencies: ["MoonshineCore"]),
        .executableTarget(name: "Moonshine", dependencies: ["MoonshineCore", "MoonshinePlatform"]),
        .executableTarget(name: "MoonshineCheck", dependencies: ["MoonshineCore", "MoonshinePlatform"]),
        .testTarget(name: "MoonshineCoreTests", dependencies: ["MoonshineCore"]),
        .testTarget(name: "MoonshinePlatformTests", dependencies: ["MoonshinePlatform", "MoonshineCore"])
    ],
    swiftLanguageModes: [.v5]
)
