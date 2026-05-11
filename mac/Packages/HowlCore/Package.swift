// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HowlCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HowlCore", targets: ["HowlCore"]),
    ],
    targets: [
        .target(
            name: "CVKB",
            path: "Sources/CVKB",
            publicHeadersPath: "include"
        ),
        // Stubs for vkb_* C ABI symbols, used ONLY by `swift test`.
        // The Xcode app build does NOT depend on this target, so the
        // app's link picks up the real symbols from libhowl.dylib
        // (-lhowl) instead of being shadowed by zero-returning stubs.
        .target(
            name: "CVKBStubs",
            path: "Sources/CVKBStubs"
        ),
        .target(
            name: "HowlCore",
            dependencies: ["CVKB"],
            path: "Sources/HowlCore"
        ),
        .testTarget(
            name: "HowlCoreTests",
            dependencies: ["HowlCore", "CVKBStubs"],
            path: "Tests/HowlCoreTests"
        ),
    ]
)
