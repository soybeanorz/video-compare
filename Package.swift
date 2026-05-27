// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VideoCompare",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "VideoCompare", targets: ["VideoCompareApp"])
    ],
    targets: [
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
            dependencies: ["CFFmpeg"],
            path: "Sources/VideoCompareApp",
            linkerSettings: [
                .unsafeFlags([
                    "-L/opt/homebrew/lib",
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
        ),
        .testTarget(
            name: "VideoCompareAppTests",
            dependencies: ["VideoCompareApp"],
            path: "Tests/VideoCompareAppTests"
        )
    ]
)
