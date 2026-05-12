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
        .target(
            name: "CFFmpeg",
            path: "Sources/CFFmpeg",
            publicHeadersPath: "include",
            cSettings: [
                .unsafeFlags(["-I/opt/homebrew/include"])
            ]
        ),
        .executableTarget(
            name: "VideoCompareApp",
            dependencies: ["CMpv", "CFFmpeg"],
            path: "Sources/VideoCompareApp",
            linkerSettings: [
                .unsafeFlags([
                    "-L/opt/homebrew/lib",
                    "-lmpv",
                    "-lavformat",
                    "-lavcodec",
                    "-lavutil",
                    "-lswscale",
                    "-framework", "VideoToolbox",
                    "-framework", "CoreMedia",
                    "-framework", "CoreVideo",
                    "-framework", "Metal",
                    "-framework", "MetalKit",
                    "-framework", "CoreImage",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/opt/homebrew/lib"
                ])
            ]
        )
    ]
)
