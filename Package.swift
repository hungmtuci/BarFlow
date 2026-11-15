// swift-tools-version: 5.10
import PackageDescription
import Foundation

let cltTestingPluginDir = "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"
let extraTestSwiftSettings: [SwiftSetting] = FileManager.default.fileExists(atPath: cltTestingPluginDir)
    ? [.unsafeFlags(["-plugin-path", cltTestingPluginDir])]
    : []

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
                .linkedFramework("ServiceManagement"),
                .unsafeFlags(["-Xlinker", "-dead_strip", "-Xlinker", "-dead_strip_dylibs"])
            ]
        ),
        .testTarget(
            name: "BarFlowTests",
            dependencies: ["BarFlow"],
            path: "Tests/BarFlowTests",
            swiftSettings: extraTestSwiftSettings
        )
    ]
)
