// swift-tools-version: 6.0
import Foundation
import PackageDescription

/// Embeds a development Info.plist in the bare executable so `swift run` and snapshot renders have a bundle
/// identity and can show Korean. The packaged app uses its own Info.plist from scripts/build-app.sh.
let embeddedInfoPlist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Support/Info.plist").path

let package = Package(
    name: "Prism",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Prism", targets: ["Prism"]),
    ],
    targets: [
        // Platform-independent search logic. Keep AppKit and SwiftUI out of this target.
        .target(name: "PrismCore"),
        .testTarget(name: "PrismCoreTests", dependencies: ["PrismCore"]),

        // Shared contracts and services for feature modules: palette providers, settings panes,
        // storage, keychain and paste. Features depend only on this, never on each other or on the app.
        .target(name: "PrismKit", dependencies: ["PrismCore"], resources: [.process("Resources")]),
        .testTarget(name: "PrismKitTests", dependencies: ["PrismKit"]),

        // Feature modules. Each one builds and tests on its own:
        //   swift build --target PrismClipboard && swift test --filter PrismClipboardTests
        .target(name: "PrismCalculator", dependencies: ["PrismKit"], resources: [.process("Resources")]),
        .testTarget(name: "PrismCalculatorTests", dependencies: ["PrismCalculator"]),
        .target(name: "PrismClipboard", dependencies: ["PrismKit"], resources: [.process("Resources")]),
        .testTarget(name: "PrismClipboardTests", dependencies: ["PrismClipboard"]),
        .target(name: "PrismLibrary", dependencies: ["PrismKit"], resources: [.process("Resources")]),
        .testTarget(name: "PrismLibraryTests", dependencies: ["PrismLibrary"]),
        .target(name: "PrismFiles", dependencies: ["PrismKit"], resources: [.process("Resources")]),
        .testTarget(name: "PrismFilesTests", dependencies: ["PrismFiles"]),
        .target(name: "PrismEmoji", dependencies: ["PrismKit"], resources: [.process("Resources")]),
        .testTarget(name: "PrismEmojiTests", dependencies: ["PrismEmoji"]),
        .target(name: "PrismSystem", dependencies: ["PrismKit"], resources: [.process("Resources")]),
        .testTarget(name: "PrismSystemTests", dependencies: ["PrismSystem"]),
        .target(name: "PrismScripts", dependencies: ["PrismKit"], resources: [.process("Resources")]),
        .testTarget(name: "PrismScriptsTests", dependencies: ["PrismScripts"]),
        .target(name: "PrismAI", dependencies: ["PrismKit"], resources: [.process("Resources")]),
        .testTarget(name: "PrismAITests", dependencies: ["PrismAI"]),
        .target(name: "PrismDictation", dependencies: ["PrismKit"], resources: [.process("Resources")]),
        .testTarget(name: "PrismDictationTests", dependencies: ["PrismDictation"]),
        .target(name: "PrismBackup", dependencies: ["PrismKit"], resources: [.process("Resources")]),
        .testTarget(name: "PrismBackupTests", dependencies: ["PrismBackup"]),
        .target(name: "PrismUpdates", dependencies: ["PrismKit"], resources: [.process("Resources")]),
        .testTarget(name: "PrismUpdatesTests", dependencies: ["PrismUpdates"]),

        .executableTarget(
            name: "Prism",
            dependencies: ["PrismCore", "PrismKit", "PrismCalculator", "PrismClipboard", "PrismLibrary", "PrismFiles", "PrismEmoji", "PrismSystem", "PrismScripts", "PrismAI", "PrismDictation", "PrismBackup", "PrismUpdates"],
            resources: [.process("Resources")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", embeddedInfoPlist])]
        ),
    ]
)
