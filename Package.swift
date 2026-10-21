// swift-tools-version:5.9
import PackageDescription

// DisplayMonkCore is plain Swift (no Apple frameworks) so its logic and tests also build on Linux.
// Everything that talks to the window server, IOKit or AppKit is macOS-only.
var products: [Product] = [
    .library(name: "DisplayMonkCore", targets: ["DisplayMonkCore"]),
]
var dependencies: [Package.Dependency] = []
var targets: [Target] = [
    .target(name: "DisplayMonkCore"),
    .testTarget(name: "DisplayMonkCoreTests", dependencies: ["DisplayMonkCore"]),
]

#if os(macOS)
products += [
    .library(name: "DisplayKit", targets: ["DisplayKit"]),
    .executable(name: "DisplayMonkApp", targets: ["DisplayMonkApp"]),
    .executable(name: "displaymonk", targets: ["displaymonk"]),
]
dependencies += [
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
]
targets += [
    // Objective-C declarations of CoreGraphics' private virtual display classes.
    .target(
        name: "CGVirtualDisplayBridge",
        linkerSettings: [.linkedFramework("CoreGraphics")]
    ),
    .target(
        name: "DisplayKit",
        dependencies: ["DisplayMonkCore", "CGVirtualDisplayBridge"],
        linkerSettings: [
            .linkedFramework("IOKit"),
            .linkedFramework("CoreGraphics"),
            .linkedFramework("AppKit"),
        ]
    ),
    .executableTarget(
        name: "DisplayMonkApp",
        dependencies: ["DisplayKit", "DisplayMonkCore"],
        linkerSettings: [.linkedFramework("ServiceManagement")]
    ),
    .executableTarget(
        name: "displaymonk",
        dependencies: [
            "DisplayKit",
            "DisplayMonkCore",
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ]
    ),
]
#endif

let package = Package(
    name: "DisplayMonk",
    platforms: [.macOS(.v13)],
    products: products,
    dependencies: dependencies,
    targets: targets
)
