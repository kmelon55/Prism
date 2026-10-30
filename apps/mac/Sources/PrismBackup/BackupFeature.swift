import Foundation
import PrismCore
import PrismKit

/// Backup, restore and Raycast import.
public enum BackupFeature {
    public static let settingsPaneID = "backup"
    public static let backUpCommandID = "backup:back-up-now"
    public static let importRaycastCommandID = "backup:import-raycast"

    /// Posted on the main actor after a restore or Raycast import changed data other modules cache. `userInfo`
    /// holds `changesKey`: the `BackupDataChange` raw values. The shell should reload what each one names.
    public static let dataDidChangeNotification = Notification.Name("PrismBackupDataDidChange")
    public static let changesKey = "changes"

    /// Set by the shell so imports register hotkeys through its registrar. Without it, imports write the shortcut
    /// files directly and post `.shortcuts`.
    @MainActor public static var shortcutAccess: BackupShortcutAccess?

    /// Set by the shell to every command row's localized title by ID (for example from the palette's searchable
    /// items), so the Raycast import maps only to commands that exist and shows their real names.
    @MainActor public static var commandTitles: (@MainActor () async -> [String: String])?

    @MainActor
    public static func make(context: any PrismContext) -> FeatureContribution {
        let backup = BackupModel(paths: context.paths)
        let raycast = try? RaycastImportModel(paths: context.paths, access: { shortcutAccess })
        let notify: (Set<BackupDataChange>) -> Void = { changes in
            guard !changes.isEmpty else { return }
            NotificationCenter.default.post(name: dataDidChangeNotification, object: nil,
                                            userInfo: [changesKey: changes.map(\.rawValue).sorted()])
        }
        backup.onChange = notify
        raycast?.onChange = notify
        raycast?.commandTitles = { await commandTitles?() ?? [:] }

        return FeatureContribution(
            providers: [BackupCommandsProvider(context: context, backup: backup)],
            settingsPanes: [
                SettingsPane(id: settingsPaneID, title: L10n.tr("Backup & Restore"), systemImage: "archivebox", group: .privacy, order: 10,
                             keywords: ["Bring your Raycast setup", "Import from Raycast", "Local backup", "Backup categories", "Backup folder",
                                        "Export backup", "Choose backup to review"].map(L10n.tr)) {
                    BackupSettingsView(backup: backup, raycast: raycast)
                },
            ]
        )
    }
}

/// "Back Up Prism Now" and "Import from Raycast" in the root search.
@MainActor
final class BackupCommandsProvider: PaletteProvider {
    let id = "backup"
    private weak var context: (any PrismContext)?
    private let backup: BackupModel

    init(context: any PrismContext, backup: BackupModel) {
        self.context = context
        self.backup = backup
    }

    func results(for query: String) async -> [PaletteItem] {
        let section = L10n.tr("Backup")
        let backUp = SearchCandidate(
            id: BackupFeature.backUpCommandID, title: L10n.tr("Back Up Prism Now"),
            subtitle: backup.location.map { L10n.format("Save a backup to %@", $0.lastPathComponent) } ?? L10n.tr("Choose a folder and save a backup"),
            section: section, keywords: ["backup", "export", "save", "백업", "내보내기"],
            searchAliases: ["Back Up Prism Now", "지금 Prism 백업"]
        )
        let raycast = SearchCandidate(
            id: BackupFeature.importRaycastCommandID, title: L10n.tr("Import from Raycast"),
            subtitle: L10n.tr("Bring shortcuts, aliases, snippets and quicklinks"),
            section: section, keywords: ["raycast", "import", "migrate", "rayconfig", "레이캐스트", "가져오기"],
            searchAliases: ["Import from Raycast", "Raycast에서 가져오기"]
        )
        return [
            PaletteItem(candidate: backUp, icon: .symbol("externaldrive.badge.timemachine", tint: .blue), accessory: L10n.tr("Command"), actions: [
                PaletteAction(id: "back-up", title: L10n.tr("Back Up Now"), systemImage: "externaldrive") { [weak self] in
                    guard let self else { return .dismiss }
                    guard backup.location != nil else {
                        context?.openSettings(paneID: BackupFeature.settingsPaneID)
                        return .dismiss
                    }
                    context?.hidePalette()
                    await backup.backUpNow()
                    context?.showHUD(backup.error.map(L10n.tr) ?? L10n.tr("Backup saved."))
                    return .dismiss
                },
                PaletteAction(id: "open-settings", title: L10n.tr("Open Backup Settings"), systemImage: "gearshape",
                              shortcut: .init(",", modifiers: [.command])) { [weak self] in
                    self?.context?.openSettings(paneID: BackupFeature.settingsPaneID)
                    return .dismiss
                },
            ], hiddenWhenQueryIsEmpty: true),
            PaletteItem(candidate: raycast, icon: .symbol("arrow.right.circle", tint: .red), accessory: L10n.tr("Command"), actions: [
                PaletteAction(id: "open", title: L10n.tr("Open Raycast Import"), systemImage: "square.and.arrow.down") { [weak self] in
                    self?.context?.openSettings(paneID: BackupFeature.settingsPaneID)
                    return .dismiss
                },
            ], hiddenWhenQueryIsEmpty: true),
        ]
    }
}
