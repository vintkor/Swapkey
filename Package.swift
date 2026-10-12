// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Swapkey",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Swapkey",
            path: "Sources/Swapkey",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("ApplicationServices"),
            ]
        )
    ]
)
