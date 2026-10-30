import PrismCore
import PrismKit
import SwiftUI

/// The palette's update rows: "Check for updates" (searchable, hidden from the empty root list), and the
/// update row from `usePaletteUpdate` while an update is available, installing, installed or failed.
@MainActor
final class UpdatesProvider: PaletteProvider {
    static let providerID = "prism-update"
    static let updateRowID = "prism:update"
    static let checkRowID = "prism:check-for-updates"

    let id = providerID
    private let controller: UpdateController

    init(controller: UpdateController) {
        self.controller = controller
    }

    func results(for query: String) async -> [PaletteItem] {
        [updateRow(controller.status), checkRow(controller.status)].compactMap { $0 }
    }

    func updateRow(_ status: UpdateStatus) -> PaletteItem? {
        guard status.hasPaletteRow, let version = status.version else { return nil }
        let installing = status.phase == .installing
        let title: String
        let actionTitle: String
        switch status.phase {
        case .installing:
            title = String(localized: "Installing Prism update…", bundle: .module)
            actionTitle = String(localized: "Installing…", bundle: .module)
        case .installed:
            title = String(localized: "Restart Prism to update", bundle: .module)
            actionTitle = String(localized: "Restart Prism", bundle: .module)
        case .error:
            title = String(localized: "Retry Prism update", bundle: .module)
            actionTitle = String(localized: "Download and install", bundle: .module)
        default:
            title = String(localized: "Update Prism", bundle: .module)
            actionTitle = String(localized: "Download and install", bundle: .module)
        }
        return PaletteItem(
            candidate: SearchCandidate(
                id: Self.updateRowID, title: title, subtitle: "\(status.currentTitle) → \(version)",
                section: Self.section,
                keywords: ["update", "upgrade", "restart", "업데이트", "설치", "재시작"],
                searchAliases: ["Update Prism", "Prism 업데이트"],
                rankingBoost: 72
            ),
            icon: .symbol(status.phase == .installed ? "arrow.clockwise.circle.fill" : "arrow.down.circle.fill",
                          tint: status.phase == .error ? .orange : .mint),
            accessory: installing ? String(localized: "Installing…", bundle: .module) : version,
            actions: [
                PaletteAction(id: "prism-update:run", title: actionTitle,
                              systemImage: status.phase == .installed ? "arrow.clockwise" : "arrow.down.circle") { [controller] in
                    await Self.run(controller)
                },
            ],
            // Like the Tauri app, a ready update sits above favorites when the palette opens.
            leadsEmptyQuery: true
        )
    }

    func checkRow(_ status: UpdateStatus) -> PaletteItem? {
        PaletteItem(
            candidate: SearchCandidate(
                id: Self.checkRowID, title: String(localized: "Check for updates", bundle: .module),
                subtitle: status.currentTitle, section: Self.section,
                keywords: ["update", "upgrade", "version", "업데이트", "버전"],
                searchAliases: ["Check for updates", "업데이트 확인"]
            ),
            icon: .symbol("arrow.triangle.2.circlepath"),
            accessory: String(localized: "Command", bundle: .module),
            actions: [
                PaletteAction(id: "prism-update:check", title: String(localized: "Check for updates", bundle: .module),
                              systemImage: "arrow.triangle.2.circlepath") { [controller] in
                    await Self.check(controller)
                },
            ],
            hiddenWhenQueryIsEmpty: true
        )
    }

    private static var section: String { String(localized: "Prism updates", bundle: .module) }

    /// Installs, retries or restarts. The row itself shows progress, so the palette stays as it is.
    static func run(_ controller: UpdateController) async -> PaletteActionOutcome {
        let status = controller.status
        guard status.hasPaletteRow, !controller.isBusy else { return .keepOpen }
        do {
            if status.phase == .installed {
                try controller.restart()
            } else if status.canInstall {
                let result = try await controller.install()
                if result.phase == .error { return .notify(UpdateStrings.label(for: result)) }
            }
        } catch {
            return .notify(error.message)
        }
        return .keepOpen
    }

    /// Checks now and reports the result as a HUD, which also works when the row runs from a hotkey.
    static func check(_ controller: UpdateController) async -> PaletteActionOutcome {
        do {
            return .notify(UpdateStrings.label(for: try await controller.check()))
        } catch {
            return .notify(error.message)
        }
    }
}
