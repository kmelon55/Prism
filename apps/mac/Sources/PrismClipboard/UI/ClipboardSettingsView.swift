import AppKit
import Observation
import PrismKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings state. The SQLite store is authoritative; every change is written there first.
@MainActor
@Observable
final class ClipboardSettingsModel {
    enum Action: Equatable {
        case enable, disable, clear
        case retention(Int)
        case primary(ClipboardPrimaryAction)
        case pause(Int)
        case exclude(id: String, name: String)
        case include(id: String)

        var needsConfirmation: Bool {
            switch self {
            case .disable, .clear, .retention: true
            default: false
            }
        }
    }

    private(set) var state: ClipboardSettingsState?
    private(set) var busy = false
    private(set) var error: String?
    private(set) var retry: Action?
    var confirmation: Action?

    @ObservationIgnored let history: ClipboardHistory

    init(history: ClipboardHistory) {
        self.history = history
    }

    func refresh() async {
        state = await history.settings()
    }

    /// Asks before anything that deletes entries: disabling, clearing and shortening retention.
    func request(_ action: Action) {
        if case .retention(let days) = action, days >= (state?.retentionDays ?? 30) {
            return execute(action)
        }
        if action.needsConfirmation { confirmation = action } else { execute(action) }
    }

    func execute(_ action: Action) {
        guard !busy else { return }
        busy = true
        error = nil
        retry = nil
        confirmation = nil
        Task {
            defer { busy = false }
            do {
                try await history.perform { store throws(ClipboardError) in
                    switch action {
                    case .enable: try store.setEnabled(true)
                    case .disable: try store.setEnabled(false)
                    case .clear: _ = try store.clear()
                    case .retention(let days): try store.setRetention(days: days)
                    case .primary(let value): try store.setPrimaryAction(value)
                    case .pause(let minutes): try store.pauseCapture(minutes: minutes)
                    case .exclude(let id, let name): try store.addExcludedApplication(id: id, name: name)
                    case .include(let id): try store.removeExcludedApplication(id: id)
                    }
                }
                if action == .clear || action == .disable { ThumbnailLoader.shared.removeAll() }
            } catch {
                self.error = error.localizedDescription
                retry = action
            }
            await refresh()
        }
    }

    func retryLast() {
        if let retry { request(retry) } else { error = nil; Task { await refresh() } }
    }

    /// Picks an app with the standard open panel and stores its bundle identifier.
    func chooseExcludedApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(filePath: "/Applications")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = ClipboardText.localize("Exclude")
        panel.message = ClipboardText.localize("Choose an app whose clipboard changes Prism should skip.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let id = Bundle(url: url)?.bundleIdentifier else {
            error = ClipboardText.localize("The application identifier is unavailable.")
            return
        }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        execute(.exclude(id: id, name: name))
    }

    func confirmationMessage(_ action: Action) -> String {
        switch action {
        case .disable: ClipboardText.localize("Disable history and permanently delete all entries, including pins?")
        case .clear: ClipboardText.localize("Permanently delete all clipboard entries, including pins? History will stay enabled if it is on.")
        default: ClipboardText.localize("Shorten retention and permanently delete expired entries? Pinned entries will be kept.")
        }
    }
}

/// The Tauri clipboard section: the clipboard shortcut row, one card per setting, excluded applications and the
/// privacy note.
struct ClipboardSettingsView: View {
    @Bindable var model: ClipboardSettingsModel

    var body: some View {
        PrismSettingsPage(ClipboardText.localize("Clipboard")) {
            PrismSettingsGroup(Text("Clipboard shortcut", bundle: .module)) {
                PrismCommandTable(showsHeader: false) {
                    PrismCommandShortcutRow(commandID: ClipboardFeature.openHistoryCommandID, title: ClipboardText.localize("Clipboard History")) {
                        Image(systemName: "clipboard").font(.system(size: 14))
                    }
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                returnAction
                historySwitch
                captureStatus
            }
            .disabled(model.state == nil)
            exclusions
            VStack(alignment: .leading, spacing: 12) {
                retention
                clearHistory
                notices
            }
            .disabled(model.state == nil)
            privacy
        }
        .task { await model.refresh() }
        .task(id: model.state?.preferences.pausedUntilMs) {
            // Show "Recording" again when a pause expires.
            guard let until = model.state?.preferences.pausedUntilMs, until > ClipboardClock.nowMs() else { return }
            try? await Task.sleep(for: .milliseconds(until - ClipboardClock.nowMs() + 50))
            if !Task.isCancelled { await model.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: ClipboardHistory.didChange)) { _ in
            Task { await model.refresh() }
        }
        .confirmationDialog(
            Text("Confirm clipboard history change", bundle: .module),
            isPresented: Binding(get: { model.confirmation != nil }, set: { if !$0 { model.confirmation = nil } }),
            presenting: model.confirmation
        ) { action in
            Button(role: .destructive) { model.execute(action) } label: {
                switch action {
                case .disable: Text("Disable and Delete", bundle: .module)
                case .clear: Text("Delete All", bundle: .module)
                default: Text("Shorten and Delete", bundle: .module)
                }
            }
            Button(role: .cancel) {} label: { Text("Cancel", bundle: .module) }
        } message: { action in
            Text(verbatim: model.confirmationMessage(action))
        }
    }

    private var state: ClipboardSettingsState { model.state ?? ClipboardSettingsState() }

    // MARK: Cards

    private var returnAction: some View {
        PrismCardSetting(Text("Return action", bundle: .module)) {
            Text("Choose what Return and double-click do. Command+Return uses the other action.", bundle: .module)
        } control: {
            PrismWideSelect(selection: Binding(get: { state.preferences.primaryAction }, set: { model.request(.primary($0)) }), options: [
                (ClipboardPrimaryAction.paste, ClipboardText.localize("Paste to previous app")),
                (ClipboardPrimaryAction.copy, ClipboardText.localize("Copy to Clipboard")),
            ])
            .disabled(model.busy)
        }
    }

    private var historySwitch: some View {
        PrismCardSetting(Text("Clipboard history", bundle: .module)) {
            Text("Off by default. After you enable history, copied text, supported images, and local file references are saved on this device across restarts.", bundle: .module)
        } control: {
            Toggle(isOn: Binding(get: { state.enabled }, set: { model.request($0 ? .enable : .disable) })) { EmptyView() }
                .toggleStyle(.prism)
                .labelsHidden()
                .disabled(model.busy)
        }
    }

    private var captureStatus: some View {
        PrismCardSetting(Text("Capture status", bundle: .module)) {
            Text(verbatim: statusText)
            Text("Pausing keeps saved entries. Content copied while paused is not added on resume.", bundle: .module)
        } control: {
            PrismWideSelect(selection: Binding(get: { state.isPaused ? -1 : 0 }, set: { if $0 >= 0 { model.request(.pause($0)) } }),
                            options: pauseOptions)
                .disabled(model.busy || !state.enabled)
                .help(Text("Pause recording", bundle: .module))
        }
    }

    private var pauseOptions: [(value: Int, title: String)] {
        var options: [(value: Int, title: String)] = state.isPaused
            ? [(-1, ClipboardText.localize("Paused")), (0, ClipboardText.localize("Resume recording"))]
            : [(0, ClipboardText.localize("Recording clipboard changes"))]
        options += [(5, ClipboardText.localize("Pause for 5 minutes")), (15, ClipboardText.localize("Pause for 15 minutes")),
                    (60, ClipboardText.localize("Pause for 1 hour"))]
        return options
    }

    private var statusText: String {
        guard state.enabled else { return ClipboardText.localize("History is off") }
        guard state.isPaused else { return ClipboardText.localize("Recording clipboard changes") }
        let until = Date(timeIntervalSince1970: TimeInterval(state.preferences.pausedUntilMs) / 1000)
        return String(format: ClipboardText.localize("Recording paused until %@"), ClipboardFormat.time(until))
    }

    private var retention: some View {
        PrismCardSetting(Text("Keep history for", bundle: .module)) {
            Text("Pinned entries stay until deleted. Up to 1,000 entries and 128 MB total: text 128 KB, images 8 MB, and 64 file references per entry.", bundle: .module)
        } control: {
            PrismWideSelect(selection: Binding(get: { state.retentionDays }, set: { model.request(.retention($0)) }), options: [
                (1, ClipboardText.localize("1 day")), (7, ClipboardText.localize("1 week")),
                (30, ClipboardText.localize("1 month")), (90, ClipboardText.localize("3 months")),
            ])
            .disabled(model.busy)
        }
    }

    private var clearHistory: some View {
        PrismCardSetting(Text("Clear stored history", bundle: .module)) {
            Text("Clear and disable both delete all saved entries, including pins. Your current system clipboard is unchanged.", bundle: .module)
            if model.state != nil {
                Text(verbatim: String(format: ClipboardText.localize("%lld entries · %lld pinned"), Int64(state.entryCount), Int64(state.pinnedCount)))
            }
        } control: {
            Button { model.request(.clear) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "trash").font(.system(size: 11))
                    Text("Clear history", bundle: .module)
                }
            }
            .buttonStyle(.prism)
            .disabled(model.busy || state.entryCount == 0)
        }
    }

    // MARK: Exclusions

    private var exclusions: some View {
        PrismSettingsGroup(Text("Excluded applications", bundle: .module)) {
            VStack(alignment: .leading, spacing: 0) {
                PrismSettingsNote(Text("On macOS, skip clipboard changes observed while these apps are active. Existing entries are kept.", bundle: .module))
                    .padding(.bottom, 8)
                ForEach(state.preferences.excludedApplications) { app in
                    HStack(spacing: 12) {
                        ExcludedAppIcon(bundleIdentifier: app.id)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: app.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(PrismTheme.text)
                            Text(verbatim: app.id).font(.system(size: 11)).foregroundStyle(PrismTheme.textMuted)
                        }
                        Spacer(minLength: 12)
                        Button { model.request(.include(id: app.id)) } label: { Text("Remove", bundle: .module) }
                            .buttonStyle(.prism)
                            .disabled(model.busy)
                    }
                    .padding(.vertical, 10)
                    Rectangle().fill(PrismTheme.separator).frame(height: 1)
                }
                Button { model.chooseExcludedApplication() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus").font(.system(size: 11))
                        Text("Add Application…", bundle: .module)
                    }
                }
                .buttonStyle(.prism)
                .disabled(model.busy || model.state == nil)
                .padding(.top, 12)
            }
        }
    }

    // MARK: Notices

    @ViewBuilder
    private var notices: some View {
        let error = model.error ?? state.persistenceError.map(ClipboardText.localize)
        if let error {
            notice(systemImage: "exclamationmark.triangle", text: error) {
                Button { model.retryLast() } label: { Text("Retry", bundle: .module) }
                    .buttonStyle(.prism)
                    .disabled(model.busy)
            }
        }
        if let captureNotice = state.captureNotice {
            notice(systemImage: "info.circle", text: ClipboardText.localize(captureNotice)) { EmptyView() }
        }
        if state.enabled && state.pinnedCount >= state.capacity {
            notice(systemImage: "pin", text: ClipboardText.localize("All history slots are pinned. Unpin or delete an entry to capture new content.")) { EmptyView() }
        }
    }

    private func notice<Accessory: View>(systemImage: String, text: String, @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: systemImage).font(.system(size: 13)).foregroundStyle(PrismTheme.textSecondary)
            Text(verbatim: text).font(.system(size: 11)).foregroundStyle(PrismTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            accessory()
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 11)
        .prismSettingsCard(cornerRadius: 12)
    }

    // MARK: Privacy

    /// `.preference-note`: an icon beside the privacy promise and the supported formats.
    private var privacy: some View {
        HStack(alignment: .center, spacing: 13) {
            Image(systemName: "clipboard").font(.system(size: 14)).foregroundStyle(PrismTheme.textSecondary)
            VStack(alignment: .leading, spacing: 5) {
                Text("Private by design", bundle: .module).font(.system(size: 11, weight: .semibold)).foregroundStyle(PrismTheme.text)
                Group {
                    Text("Stored locally without a network connection. Private, concealed, and transient macOS items and obvious text credentials are skipped. Unmarked sensitive content may still be saved. File contents are never read or stored.", bundle: .module)
                    Text("macOS supports PNG, JPEG, WebP, TIFF, and local file references. TIFF is saved as PNG. Images are limited to 8,192 pixels per side and 16 megapixels. HEIC, GIF, HTML-only, and mixed items are skipped.", bundle: .module)
                }
                .font(.system(size: 11))
                .foregroundStyle(PrismTheme.textMuted)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(PrismTheme.surface))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(PrismTheme.line))
    }
}

private struct ExcludedAppIcon: View {
    let bundleIdentifier: String

    var body: some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            Image(nsImage: AppIconCache.shared.icon(forPath: url.path)).resizable().frame(width: 24, height: 24)
        } else {
            Image(systemName: "app.dashed").font(.system(size: 18)).frame(width: 24, height: 24).foregroundStyle(PrismTheme.textMuted)
        }
    }
}
