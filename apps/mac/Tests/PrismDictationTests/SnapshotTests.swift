import AppKit
import PrismKit
import SwiftUI
import Testing
@testable import PrismDictation

/// Renders the overlay states and the model picker to PNG for visual review. Runs only when
/// `PRISM_DICTATION_SNAPSHOTS` names an output folder; it never shows windows on screen.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["PRISM_DICTATION_SNAPSHOTS"] != nil))
struct SnapshotTests {
    private var output: URL { URL(filePath: ProcessInfo.processInfo.environment["PRISM_DICTATION_SNAPSHOTS"] ?? NSTemporaryDirectory()) }

    @Test func overlayStates() async throws {
        _ = NSApplication.shared
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            NSApp.appearance = NSAppearance(named: appearance)
            let suffix = appearance == .aqua ? "light" : "dark"
            let controller = DictationController(recorder: FakeRecorder(), presentsOverlay: false)
            var settings = DictationSettings()
            settings.enhancementMode = .cleanup
            controller.preview(settings: settings, controls: RecordingControlSettings(settings: settings, primary: .doubleModifier(.control)))
            try await render(DictationOverlayView(controller: controller, message: nil, usesNativeGlass: false),
                             width: OverlayPresenter.contentWidth(for: controller) + 24, height: 74, name: "overlay-recording-\(suffix)")
            controller.cancel()
            controller.preview(settings: settings, controls: RecordingControlSettings())
            try await Task.sleep(for: .seconds(3.2))
            try await render(DictationOverlayView(controller: controller, message: nil, usesNativeGlass: false),
                             width: OverlayPresenter.contentWidth(for: controller) + 24, height: 74, name: "overlay-transcribing-\(suffix)")
            controller.cancel()
            controller.fail(TextDeliveryResult.permissionRequired.fallbackMessage)
            try await render(DictationOverlayView(controller: controller, message: controller.message, usesNativeGlass: false),
                             width: 354, height: 82, name: "overlay-toast-\(suffix)")
            controller.cancel()
        }
    }

    @Test func modelPicker() async throws {
        _ = NSApplication.shared
        let folder = TemporaryDirectory()
        for (appearance, provider) in [(NSAppearance.Name.aqua, SpeechProvider.local), (.darkAqua, .local), (.aqua, .xai), (.aqua, .groq)] {
            NSApp.appearance = NSAppearance(named: appearance)
            let service = DictationService(paths: AppPaths(dataDirectory: folder.url), context: nil,
                                           keys: DictationKeys(service: "dev.prism.native-tests.snapshots", storage: MemoryKeyStorage()))
            service.update(service.settings.changingProvider(to: provider))
            try await render(ModelPickerSheet(service: service), width: 580, height: 520,
                             name: "picker-\(provider.rawValue)-\(appearance == .aqua ? "light" : "dark")")
        }
    }

    private func render<Content: View>(_ view: Content, width: CGFloat, height: CGFloat, name: String) async throws {
        let hosting = NSHostingView(rootView: view.frame(width: width, height: height).background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: width, height: height), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(400))
        hosting.layoutSubtreeIfNeeded()
        let representation = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: representation)
        try representation.representation(using: .png, properties: [:])?.write(to: output.appending(path: "\(name).png"))
        window.orderOut(nil)
    }
}
