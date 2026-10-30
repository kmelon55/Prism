import AppKit
import PrismCore
import PrismKit

/// Installed apps. The catalog rescans in the background each time the palette opens and keeps
/// serving the previous scan until the new one finishes.
@MainActor
final class ApplicationsProvider: PaletteProvider {
    let id = "applications"
    private var applications: [InstalledApplication] = []
    private var scan: Task<Void, Never>?
    private var hasLoaded = false
    /// Opens Settings → Commands filtered to the app, where it gets an alias, a hotkey or is turned off.
    var onConfigure: ((String) -> Void)?

    func reload() {
        guard scan == nil else { return }
        scan = Task {
            applications = await Task.detached(priority: .userInitiated) { ApplicationCatalog.scan() }.value
            hasLoaded = true
            scan = nil
        }
    }

    func results(for query: String) async -> [PaletteItem] {
        if !hasLoaded { await scan?.value }
        return applications.map(item)
    }

    private func item(_ application: InstalledApplication) -> PaletteItem {
        let url = URL(filePath: application.path)
        var candidate = application.searchCandidate
        candidate.section = String(localized: "Applications", bundle: .module)
        return PaletteItem(
            candidate: candidate,
            icon: .file(path: application.path),
            accessory: String(localized: "Application", bundle: .module),
            actions: [
                PaletteAction(id: "open", title: String(localized: "Open Application", bundle: .module), systemImage: "arrow.up.forward.app") {
                    _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                    return .dismiss
                },
                PaletteAction(id: "reveal", title: String(localized: "Show in Finder", bundle: .module), systemImage: "folder",
                              shortcut: .init("r", modifiers: [.command, .shift])) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                    return .dismiss
                },
                PaletteAction(id: "copy-path", title: String(localized: "Copy Path", bundle: .module), systemImage: "doc.on.doc",
                              shortcut: .init("c", modifiers: [.command, .shift])) {
                    PasteService.copy(application.path)
                    return .notify(String(localized: "Copied to Clipboard", bundle: .module))
                },
                PaletteAction(id: "configure", title: String(localized: "Configure Application", bundle: .module),
                              systemImage: "slider.horizontal.3", shortcut: .init(",", modifiers: .command)) { [weak self] in
                    self?.onConfigure?(application.name)
                    return .dismiss
                },
            ]
        )
    }
}
