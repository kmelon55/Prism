import AppKit
import PrismCore
import PrismKit

/// System Settings destinations, Lock Screen, power actions, Empty Trash and Quit All Apps.
@MainActor
final class SystemCommandsProvider: PaletteProvider {
    let id = "system"
    private let runner: SystemActionRunner

    init(runner: SystemActionRunner) {
        self.runner = runner
    }

    func results(for query: String) async -> [PaletteItem] {
        // The small boost only settles ties with same-named apps; the empty query leads with apps and recent rows.
        let boost = query.trimmingCharacters(in: .whitespaces).isEmpty ? 0 : 0.2
        return SystemSetting.allCases.map(item) + SystemAction.allCases.map { item($0, boost: boost) }
    }

    private func item(_ setting: SystemSetting) -> PaletteItem {
        PaletteItem(
            candidate: SearchCandidate(
                id: setting.commandID, title: setting.title, subtitle: setting.subtitle,
                section: String(localized: "System Settings", bundle: .module),
                keywords: setting.keywords, searchAliases: SystemStrings.bilingual(setting.englishTitle)
            ),
            icon: setting.iconPath.map { .file(path: $0) } ?? .symbol(setting.systemImage),
            accessory: String(localized: "System Settings", bundle: .module),
            actions: [
                PaletteAction(id: "open-system-setting", title: String(localized: "Open \(setting.title)", bundle: .module),
                              systemImage: "gearshape") {
                    NSWorkspace.shared.open(setting.url)
                    return .dismiss
                },
            ]
        )
    }

    private func item(_ action: SystemAction, boost: Double) -> PaletteItem {
        PaletteItem(
            candidate: SearchCandidate(
                id: action.commandID, title: action.title, subtitle: action.subtitle,
                section: String(localized: "System Actions", bundle: .module),
                keywords: action.keywords, searchAliases: SystemStrings.bilingual(action.englishTitle),
                rankingBoost: boost
            ),
            icon: action.iconPath.map { .file(path: $0) } ?? .symbol(action.systemImage, tint: action.needsConfirmation ? .red : nil),
            accessory: String(localized: "Command", bundle: .module),
            actions: [
                PaletteAction(id: action == .lockScreen ? "lock-screen" : "run-system-action", title: action.title,
                              systemImage: action.systemImage, isDestructive: action.needsConfirmation) { [runner] in
                    await runner.start(action)
                },
            ]
        )
    }
}

/// Runs system actions with the Tauri rules: confirmation for session-ending actions, one pending request at a time,
/// and cancellation that leaves the palette open.
@MainActor
final class SystemActionRunner {
    private unowned let context: any PrismContext
    private let execute: @MainActor (SystemAction) async throws -> Void
    private(set) var isBusy = false

    init(context: any PrismContext, execute: @escaping @MainActor (SystemAction) async throws -> Void = SystemActionExecutor.execute) {
        self.context = context
        self.execute = execute
    }

    /// The palette outcome for running `action`: a confirmation screen, or the result of running it directly.
    func start(_ action: SystemAction) async -> PaletteActionOutcome {
        guard !isBusy else { return .notify(String(localized: "A system action is already pending.", bundle: .module)) }
        guard action.needsConfirmation else { return await perform(action) }
        if action == .quitAllApps, SystemActionExecutor.quittableApplications().isEmpty {
            return .notify(String(localized: "No apps to quit", bundle: .module))
        }
        return .push(confirmationScreen(for: action))
    }

    func confirmationScreen(for action: SystemAction) -> PaletteScreen {
        let detail = action == .quitAllApps ? SystemActionExecutor.quittableApplications().compactMap(\.localizedName) : []
        return PaletteScreen(id: "system-confirm:\(action.rawValue)", title: action.title) { [weak self] in
            ConfirmationView(
                systemImage: action.systemImage,
                title: action.title,
                message: action.confirmationMessage,
                confirmTitle: action.title,
                detail: detail,
                onConfirm: { [weak self] in
                    guard let self else { return }
                    Task { _ = await self.perform(action) }
                },
                onCancel: {
                    // The palette pops the screen on Escape and keeps the query.
                    NSApp.sendAction(#selector(NSResponder.cancelOperation(_:)), to: nil, from: nil)
                }
            )
        }
    }

    @discardableResult
    func perform(_ action: SystemAction) async -> PaletteActionOutcome {
        guard !isBusy else { return .notify(String(localized: "A system action is already pending.", bundle: .module)) }
        isBusy = true
        defer { isBusy = false }
        context.hidePalette()
        do {
            try await execute(action)
            return .dismiss
        } catch let error as SystemActionError {
            context.showHUD(error.message)
            return .dismiss
        } catch {
            context.showHUD(error.localizedDescription)
            return .dismiss
        }
    }
}
