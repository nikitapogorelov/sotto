// swift-tools-version: 6.0
// Tools version 6.0 is required for swift-testing support in `swift test`
// (XCTest is unavailable with Command Line Tools alone). Both targets stay
// in Swift 5 language mode — no strict-concurrency migration implied.
import PackageDescription

let package = Package(
    name: "Sotto",
    // 14.2 is where the per-process audio objects landed
    // (kAudioHardwarePropertyProcessObjectList); call detection attributes
    // microphone use to a specific process through them.
    platforms: [.macOS("14.2")],
    dependencies: [
        // Pinned to v1.7.2 (commit 6266a9f): the last release whose Package.swift
        // builds whisper from source (with Metal). v1.7.3/v1.7.4 switched to a
        // pkg-config system library and later releases dropped SwiftPM entirely in
        // favor of an xcframework. Pinned by revision, not version, because SPM
        // rejects versioned dependencies that use unsafeFlags.
        .package(url: "https://github.com/ggml-org/whisper.cpp.git", revision: "6266a9f9e56a5b925e9892acf650f3eb1245814d"),
        // Pinned to 1.15.0: every later release (through 3.x) uses the #Preview
        // macro, which fails to compile with Command Line Tools alone (the
        // PreviewsMacros plugin ships only with full Xcode).
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", exact: "1.15.0")
    ],
    targets: [
        .executableTarget(
            name: "Sotto",
            dependencies: [
                .product(name: "whisper", package: "whisper.cpp"),
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts")
            ],
            path: "Sources/Sotto",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "SottoTests",
            dependencies: ["Sotto"],
            path: "Tests/SottoTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
