import AppKit
import Observation
import PrismKit
import SwiftUI

/// State for the Files screen: search with a type filter, selection, preview, the ⌘K action list and the
/// Open With chooser.
@MainActor
@Observable
final class FileBrowserModel {
    static let resultLimit = 200

    var query: String { didSet { if query != oldValue { scheduleSearch() } } }
    var filter: FileTypeFilter = .all { didSet { if filter != oldValue { scheduleSearch(immediately: true) } } }
    private(set) var results: [FileHit] = []
    private(set) var total = 0
    private(set) var isSearching = false
    /// True once results for the current query and filter have arrived.
    private(set) var isCurrent = false
    var selection = 0 { didSet { QuickLookPanel.shared.updateIfVisible(selectedHit?.url) } }
    private(set) var showsActions = false
    var actionSelection = 0
    private(set) var openWithTarget: FileHit?
    private(set) var status: String?

    let service: FileSearchService
    @ObservationIgnored private weak var context: (any PrismContext)?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var statusTask: Task<Void, Never>?

    init(service: FileSearchService, context: (any PrismContext)?, query: String = "") {
        self.service = service
        self.context = context
        self.query = query
    }

    var selectedHit: FileHit? { results.indices.contains(selection) ? results[selection] : nil }

    var selectedActions: [PaletteAction] {
        guard let hit = selectedHit else { return [] }
        return FileActions.actions(for: hit) { [weak self] hit in
            self?.showsActions = false
            self?.openWithTarget = hit
            return .keepOpen
        }
    }

    func start() {
        service.refresh()
        scheduleSearch(immediately: true)
    }

    func scheduleSearch(immediately: Bool = false) {
        searchTask?.cancel()
        isCurrent = false
        isSearching = true
        let query = query
        let filter = filter
        let previousID = selectedHit?.id
        searchTask = Task {
            if !immediately { try? await Task.sleep(for: .milliseconds(90)) }
            guard !Task.isCancelled else { return }
            let found: (hits: [FileHit], total: Int)
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let recent = await service.recent(filter: filter)
                found = (recent, recent.count)
            } else {
                found = await service.search(query, filter: filter, limit: Self.resultLimit)
            }
            guard !Task.isCancelled else { return }
            results = found.hits
            total = found.total
            selection = previousID.flatMap { id in found.hits.firstIndex { $0.id == id } } ?? 0
            isSearching = false
            isCurrent = true
        }
    }

    // MARK: Keyboard

    func handle(_ command: SearchFieldCommand) -> Bool {
        if showsActions {
            let count = selectedActions.count
            switch command {
            case .up: actionSelection = max(actionSelection - 1, 0)
            case .down: actionSelection = min(actionSelection + 1, max(count - 1, 0))
            case .submit:
                let actions = selectedActions
                showsActions = false
                if actions.indices.contains(actionSelection) { perform(actions[actionSelection]) }
            case .cancel: showsActions = false
            default: return true
            }
            return true
        }
        switch command {
        case .up: move(by: -1)
        case .down: move(by: 1)
        case .pageUp: move(by: -8)
        case .pageDown: move(by: 8)
        case .submit: if let action = selectedActions.first { perform(action) }
        case .commandSubmit: if let reveal = selectedActions.first(where: { $0.id == "file-reveal" }) { perform(reveal) }
        case .tab: cycleFilter(by: 1)
        case .backTab: cycleFilter(by: -1)
        case .cancel:
            if QuickLookPanel.shared.isVisible {
                QuickLookPanel.shared.close()
            } else if !query.isEmpty {
                query = ""
            } else {
                return false
            }
        case .left, .right: return false
        }
        return true
    }

    func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if modifiers == .command, key == "k" {
            toggleActions()
            return true
        }
        guard let action = selectedActions.first(where: { $0.shortcut.map { Self.matches($0, key: key, modifiers: modifiers) } ?? false }) else { return false }
        showsActions = false
        perform(action)
        return true
    }

    static func matches(_ shortcut: KeyboardShortcut, key: String, modifiers: NSEvent.ModifierFlags) -> Bool {
        var expected: NSEvent.ModifierFlags = []
        if shortcut.modifiers.contains(.command) { expected.insert(.command) }
        if shortcut.modifiers.contains(.shift) { expected.insert(.shift) }
        if shortcut.modifiers.contains(.option) { expected.insert(.option) }
        if shortcut.modifiers.contains(.control) { expected.insert(.control) }
        return expected == modifiers.intersection([.command, .shift, .option, .control])
            && String(shortcut.key.character).lowercased() == key
    }

    func move(by delta: Int) {
        guard !results.isEmpty else { return }
        selection = min(max(selection + delta, 0), results.count - 1)
    }

    func cycleFilter(by delta: Int) {
        let all = FileTypeFilter.allCases
        let index = all.firstIndex(of: filter) ?? 0
        filter = all[(index + delta + all.count) % all.count]
    }

    func toggleActions() {
        guard selectedHit != nil else { showsActions = false; return }
        actionSelection = 0
        showsActions.toggle()
    }

    func closeOpenWith() { openWithTarget = nil }

    func perform(_ action: PaletteAction) {
        Task {
            switch await action.run() {
            case .dismiss: context?.hidePalette()
            case .keepOpen, .push: break
            case .refresh: scheduleSearch(immediately: true)
            case .notify(let message): show(status: message)
            }
        }
    }

    private func show(status message: String) {
        status = message
        statusTask?.cancel()
        statusTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            status = nil
        }
    }

    func hidePalette() { context?.hidePalette() }
}
