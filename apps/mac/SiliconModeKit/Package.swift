// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SiliconModeKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "SiliconModeKit", targets: ["SiliconModeKit"]),
    ],
    targets: [
        .target(
            name: "SiliconModeKit",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("Security"),
            ]
        ),
        .testTarget(
            name: "SiliconModeKitTests",
            dependencies: ["SiliconModeKit"]
        ),
    ]
)
