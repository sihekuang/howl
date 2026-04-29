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
        .target(
            name: "VoiceKeyboardCore",
            dependencies: ["CVKB"],
            path: "Sources/VoiceKeyboardCore"
        ),
        .testTarget(
            name: "VoiceKeyboardCoreTests",
            dependencies: ["VoiceKeyboardCore"],
            path: "Tests/VoiceKeyboardCoreTests"
        ),
    ]
)
