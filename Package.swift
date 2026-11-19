// swift-tools-version: 5.9
import PackageDescription

var targets: [Target] = [
    // Platform-neutral logic: session discovery, hook events, transcript parsing,
    // git/PR info, terminal control. Builds and tests on macOS and Linux.
    .target(
        name: "QodeNotchCore",
        path: "Sources/QodeNotchCore"
    ),
    .testTarget(
        name: "QodeNotchCoreTests",
        dependencies: ["QodeNotchCore"],
        path: "Tests/QodeNotchCoreTests"
    ),
]

#if os(macOS)
// The notch app itself (AppKit + SwiftUI) only exists on macOS.
targets.append(
    .executableTarget(
        name: "QodeNotch",
        dependencies: ["QodeNotchCore"],
        path: "Sources/QodeNotch"
    )
)
#endif

let package = Package(
    name: "QodeNotch",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "QodeNotchCore", targets: ["QodeNotchCore"]),
    ],
    targets: targets
)
