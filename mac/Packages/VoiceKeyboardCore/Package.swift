// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VoiceKeyboardCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "VoiceKeyboardCore", targets: ["VoiceKeyboardCore"]),
    ],
    targets: [
        .target(
            name: "CVKB",
            path: "Sources/CVKB",
            publicHeadersPath: "include"
        ),
        // Stubs for vkb_* C ABI symbols, used ONLY by `swift test`.
        // The Xcode app build does NOT depend on this target, so the
        // app's link picks up the real symbols from libvkb.dylib
        // (-lvkb) instead of being shadowed by zero-returning stubs.
        .target(
            name: "CVKBStubs",
            path: "Sources/CVKBStubs"
        ),
        .target(
            name: "VoiceKeyboardCore",
            dependencies: ["CVKB"],
            path: "Sources/VoiceKeyboardCore"
        ),
        .testTarget(
            name: "VoiceKeyboardCoreTests",
            dependencies: ["VoiceKeyboardCore", "CVKBStubs"],
            path: "Tests/VoiceKeyboardCoreTests"
        ),
    ]
)
