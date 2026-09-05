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
            exclude: ["Info.plist"],
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
        .target(name: "MixanimoAtomics"),
        .executableTarget(name: "Mixanimo", dependencies: ["MixanimoAtomics"]),
        .testTarget(name: "MixanimoTests", dependencies: ["Mixanimo"]),
    ]
)
