import AppKit
import PrismKit
import SwiftUI
import Testing
@testable import PrismBackup

/// Renders the settings pane with synthetic data when `PRISM_BACKUP_SNAPSHOTS` names an output folder.
/// The app's snapshot renderer cannot click, so this is how the review and import states are checked.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PRISM_BACKUP_SNAPSHOTS"] != nil))
@MainActor struct SnapshotTests {
    @Test func renderPane() async throws {
        let output = URL(filePath: ProcessInfo.processInfo.environment["PRISM_BACKUP_SNAPSHOTS"]!)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let data = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: data) }
        let paths = AppPaths(dataDirectory: data)
        let library = try BackupLibrary(url: paths.file(BackupLibrary.fileName))
        try library.database.transaction {
            try library.save(BackupEntry(id: "greeting", kind: "snippet", title: "Greeting", value: "Hello", keyword: ";hi"))
        }
        let backupFile = data.appending(path: "prism-backup-v2.json")
        try BackupDocument(version: 3, entries: [
            BackupEntry(id: "greeting", kind: "snippet", title: "Greeting", value: "Hello", keyword: ";hi"),
            BackupEntry(id: "sig", kind: "snippet", title: "Signature", value: "Thanks"),
            BackupEntry(id: "meeting", kind: "note", title: "Meeting notes", value: "# Notes"),
            BackupEntry(id: "docs", kind: "link", title: "Docs", value: "https://example.com/?q={query}"),
        ], favorites: [BackupFavorite(id: "library:docs", title: "Docs"), BackupFavorite(id: "library:gone", title: "Removed")],
        preferences: Fixtures.preferences(aliases: ["window:left-half": "lh", "prism:emoji": "emo"])).encoded().write(to: backupFile)
        let raycastFile = data.appending(path: "export.json")
        var classic = RaycastFileTests.classic
        classic["builtin_package_clipboardHistory"] = [:]
        try Fixtures.json(classic).write(to: raycastFile)

        for (language, appearance) in [("en", NSAppearance.Name.aqua), ("en", .darkAqua), ("ko", .aqua)] {
            let suite = "PrismBackupSnapshot.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            L10n.overrideBundle = language == "ko" ? Bundle(path: Bundle.module.path(forResource: "ko", ofType: "lproj")!) : nil
            defer { L10n.overrideBundle = nil }
            let backup = BackupModel(paths: paths, defaults: defaults, domain: suite)
            backup.categories.preferences = true
            let raycast = try RaycastImportModel(paths: paths, access: { nil })
            raycast.loadJournal()
            await backup.review(backupFile)
            await raycast.reviewFile(raycastFile)
            let view = BackupSettingsView(backup: backup, raycast: raycast)
                .environment(\.locale, Locale(identifier: language))
                .frame(width: 600, height: 2100)
                .background(Color(nsColor: .windowBackgroundColor))
            let name = "backup-\(language)-\(appearance == .darkAqua ? "dark" : "light").png"
            render(view, appearance: appearance, size: CGSize(width: 600, height: 2100), to: output.appending(path: name))
        }
    }

    private func render<Content: View>(_ view: Content, appearance: NSAppearance.Name, size: CGSize, to url: URL) {
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = NSAppearance(named: appearance)
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -20_000, y: -20_000), size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = hosting
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        hosting.layoutSubtreeIfNeeded()
        guard let representation = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: representation)
        try? representation.representation(using: .png, properties: [:])?.write(to: url)
        window.orderOut(nil)
    }
}
