// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "BarFlow",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "BarFlow", targets: ["BarFlow"])
    ],
    targets: [
        .executableTarget(
            name: "BarFlow",
            path: "Sources/BarFlow",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ScreenCaptureKit")
            ]
        )
    ]
)
