import AppKit
import SwiftUI
import Testing
@testable import PrismUpdates

/// Renders Settings → Updates in every reachable state for a visual check. Opt-in:
/// `PRISM_UPDATES_SNAPSHOTS=/some/dir swift test --filter UpdatesSnapshotTests`.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["PRISM_UPDATES_SNAPSHOTS"] != nil))
struct UpdatesSnapshotTests {
    let directory = URL(filePath: ProcessInfo.processInfo.environment["PRISM_UPDATES_SNAPSHOTS"] ?? "/dev/null")

    @Test func rendersEveryState() async throws {
        let available = Harness()
        available.publishUpdate()
        _ = try await available.controller.check()

        let failed = Harness(verifier: FakeVerifier(accepts: false))
        failed.publishUpdate()
        _ = try await failed.controller.check()
        _ = try await failed.controller.install()

        let installed = Harness()
        installed.publishUpdate()
        _ = try await installed.controller.check()
        _ = try await installed.controller.install()
        try installed.controller.setAutomaticInstall(true)

        let installing = Harness()
        installing.publishUpdate()
        _ = try await installing.controller.check()
        MockURLProtocol.serve(installing.archiveURL, .init(body: makeUpdateArchive(version: "0.2.0"), delay: 5))
        let task = Task { try await installing.controller.install() }
        await installing.waitUntil { installing.controller.status.phase == .installing }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, harness) in [("available", available), ("error", failed), ("installed", installed), ("installing", installing)] {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                await render(UpdatesSettingsView(controller: harness.controller), appearance: appearance,
                             to: directory.appending(path: "updates-\(name)-\(appearance == .aqua ? "light" : "dark").png"))
            }
        }
        task.cancel()
    }

    private func render(_ view: some View, appearance: NSAppearance.Name, to url: URL) async {
        let hosting = NSHostingView(rootView: view.frame(width: 560, height: 360).background(Color(nsColor: .windowBackgroundColor)))
        hosting.appearance = NSAppearance(named: appearance)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 560, height: 360), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = hosting
        window.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(300))
        hosting.layoutSubtreeIfNeeded()
        guard let representation = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: representation)
        try? representation.representation(using: .png, properties: [:])?.write(to: url)
        window.orderOut(nil)
    }
}
