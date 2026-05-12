// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VideoCompare",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "VideoCompare", targets: ["VideoCompareApp"])
    ],
    targets: [
        .systemLibrary(
            name: "CMpv",
            path: "Sources/CMpv",
            pkgConfig: "mpv"
        ),
        .executableTarget(
            name: "VideoCompareApp",
            dependencies: ["CMpv"],
            path: "Sources/VideoCompareApp",
            linkerSettings: [
                .unsafeFlags(["-L/opt/homebrew/lib", "-lmpv", "-Xlinker", "-rpath", "-Xlinker", "/opt/homebrew/lib"])
            ]
        )
    ]
)
