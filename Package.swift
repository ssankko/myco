// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Mixanimo",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MixanimoDriver", type: .dynamic, targets: ["MixanimoDriver"]),
        .executable(name: "Mixanimo", targets: ["Mixanimo"]),
    ],
    targets: [
        .target(
            name: "MixanimoDriver",
            dependencies: ["MixanimoAtomics"],
            exclude: ["Info.plist"],
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
        .target(name: "MixanimoAtomics"),
        .target(name: "MixanimoDSP", dependencies: ["MixanimoAtomics"]),
        .target(name: "MixanimoEngine", dependencies: ["MixanimoDSP", "MixanimoAtomics"]),
        .executableTarget(name: "Mixanimo", dependencies: ["MixanimoEngine", "MixanimoDSP"]),
        // Signal measurements both test targets assert on.
        .target(name: "MixanimoTestSupport", path: "Tests/MixanimoTestSupport"),
        .testTarget(name: "MixanimoDSPTests", dependencies: ["MixanimoDSP", "MixanimoTestSupport"]),
        .testTarget(
            name: "MixanimoEngineTests", dependencies: ["MixanimoEngine", "MixanimoTestSupport"]),
    ]
)
