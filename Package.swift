// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Myco",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MycoDriver", type: .dynamic, targets: ["MycoDriver"]),
        .executable(name: "Myco", targets: ["Myco"]),
    ],
    targets: [
        .target(
            name: "MycoDriver",
            dependencies: ["MycoAtomics"],
            exclude: ["Info.plist"],
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
        .target(name: "MycoAtomics"),
        .target(name: "MycoDSP", dependencies: ["MycoAtomics"]),
        .target(name: "MycoEngine", dependencies: ["MycoDSP", "MycoAtomics"]),
        .executableTarget(
            name: "Myco", dependencies: ["MycoEngine", "MycoDSP"], exclude: ["Myco.svg", "Resources"]),
        // Signal measurements both test targets assert on.
        .target(name: "MycoTestSupport", path: "Tests/MycoTestSupport"),
        .testTarget(name: "MycoDSPTests", dependencies: ["MycoDSP", "MycoTestSupport"]),
        .testTarget(
            name: "MycoEngineTests", dependencies: ["MycoEngine", "MycoTestSupport"]),
    ]
)
