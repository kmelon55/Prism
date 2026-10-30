import AppKit
import PrismKit
import SwiftUI

/// Change Model: choose a speech provider, then a catalog model, a local Whisper model or a manual ID.
struct ModelPickerSheet: View {
    let service: DictationService
    @Environment(\.dismiss) private var dismiss
    @ViewState private var error: String?

    private var settings: DictationSettings { service.settings }

    var body: some View {
        PrismPickerPanel {
            PrismPickerHeader(Text("Speech model", bundle: .module), onClose: { dismiss() })
            PrismPillTabs(selection: Binding(get: { settings.provider }, set: { provider in
                guard provider != settings.provider else { return }
                error = nil
                service.update(settings.changingProvider(to: provider))
            }), options: SpeechProvider.allCases.map { ($0, $0.shortTitle) }, fontSize: 11.5, expands: true)
            Group {
                if settings.provider == .local {
                    LocalModelList(service: service, onChosen: { dismiss() })
                } else {
                    RemoteModelList(service: service, onChosen: { dismiss() })
                        .id(settings.provider)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: 600, height: 540)
    }
}

/// A selectable speech model card (`.dictation-model` in the picker dialog): bordered, raised when chosen.
private struct ModelCard<Content: View>: View {
    let selected: Bool
    let highlighted: Bool
    let action: () -> Void
    @ViewBuilder let content: () -> Content
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) { content() }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected || highlighted || hovering ? PrismTheme.surfaceSelected : .clear))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(selected ? PrismTheme.accent.opacity(0.7) : PrismTheme.lineStrong))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: Remote

private struct RemoteModelList: View {
    let service: DictationService
    let onChosen: () -> Void
    @ViewState private var catalog: SpeechModelCatalog?
    @ViewState private var loading = false
    @ViewState private var error: String?
    @ViewState private var query = ""
    @ViewState private var selection: String?
    @ViewState private var manualModel = ""
    @ViewState private var refreshCount = 0
    @FocusState private var searchFocused: Bool

    private var settings: DictationSettings { service.settings }
    private var keyConfigured: Bool { service.keyInfo(for: settings.provider).configured }
    private var canLoad: Bool { (settings.provider == .vercel || settings.provider == .xai || keyConfigured) && !settings.baseURL.isEmpty }

    private var filtered: [SpeechModel] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return catalog?.models ?? [] }
        return (catalog?.models ?? []).filter { model in
            let haystack = "\(model.name) \(model.id) \(model.ownedBy)".lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if settings.provider == .xai {
                xai
            } else {
                if settings.provider == .custom || (settings.provider != .vercel && !keyConfigured) {
                    connection
                }
                HStack(spacing: 8) {
                    PrismSearchWell {
                        TextField(text: $query, prompt: Text("Search by model or maker", bundle: .module)) { EmptyView() }
                            .focused($searchFocused)
                            .onSubmit(chooseSelection)
                            .onKeyPress(.downArrow) { move(1); return .handled }
                            .onKeyPress(.upArrow) { move(-1); return .handled }
                    }
                    Button { refreshCount += 1 } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .medium)).frame(width: 16, height: 38)
                    }
                    .buttonStyle(.prism)
                    .help(Text("Refresh models", bundle: .module))
                    .disabled(!canLoad || loading)
                }
                list
                manual
            }
        }
        .task(id: "\(settings.provider.rawValue)|\(settings.baseURL)|\(service.keyRevision)|\(refreshCount)|\(canLoad)") { await load() }
        .onAppear {
            manualModel = settings.model
            selection = settings.model.isEmpty ? nil : settings.model
            searchFocused = true
        }
    }

    @ViewBuilder
    private var list: some View {
        if !canLoad {
            note(Text("Set the API key and address to load supported models.", bundle: .module), systemImage: "key")
        } else if loading, catalog == nil {
            VStack { ProgressView().controlSize(.small); Text("Loading supported models…", bundle: .module).font(.system(size: 12)).foregroundStyle(PrismTheme.textMuted) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error {
            note(Text(verbatim: error), systemImage: "exclamationmark.triangle")
        } else if let catalog, catalog.models.isEmpty {
            note(Text("The API response lists no file transcription models. Check the server documentation or enter a model ID.", bundle: .module),
                 systemImage: "tray")
        } else if catalog != nil, filtered.isEmpty {
            note(Text("No results.", bundle: .module), systemImage: "magnifyingglass")
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(filtered) { model in
                            ModelCard(selected: model.id == settings.model, highlighted: model.id == selection) {
                                selection = model.id
                                choose(model.id)
                            } content: {
                                SpeechModelRow(model: model, selected: model.id == settings.model)
                            }
                            .disabled(!model.batchCompatible)
                            .id(model.id)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(minHeight: 0, maxHeight: .infinity)
                .layoutPriority(-1)
                .onChange(of: selection) { _, id in if let id { proxy.scrollTo(id) } }
            }
            if let catalog {
                HStack {
                    Text("Transcription models confirmed by the provider API", bundle: .module) + Text(verbatim: " · \(catalog.models.count)")
                    Spacer()
                    Button { chooseSelection() } label: { Text("Use Model", bundle: .module) }
                        .buttonStyle(.prism)
                        .keyboardShortcut(searchFocused ? nil : .defaultAction)
                        .disabled(!selectable(selection))
                }
                .font(.system(size: 11))
                .foregroundStyle(PrismTheme.textMuted)
            }
        }
    }

    private var manual: some View {
        PrismDisclosure(Text("Enter a model ID", bundle: .module)) {
            VStack(alignment: .leading, spacing: 8) {
                DictationNote(Text("Check the provider's documentation to confirm that a manual ID supports file transcription.", bundle: .module))
                HStack(spacing: 6) {
                    TextField(text: $manualModel, prompt: Text("File transcription model ID", bundle: .module)) { EmptyView() }
                        .labelsHidden()
                        .textFieldStyle(.prism)
                        .onSubmit { choose(manualModel) }
                    Button { choose(manualModel) } label: { Text("Use This Model", bundle: .module) }
                        .buttonStyle(.prism)
                        .disabled(manualModel.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(.leading, 15)
        }
        .padding(.top, 4)
    }

    /// The key and address the catalog needs, so the picker never dead-ends.
    private var connection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if settings.provider == .custom {
                LabeledContent {
                    TextField(text: Binding(get: { service.settings.baseURL }, set: { value in
                        var next = service.settings
                        next.baseURL = value
                        service.update(next, delay: .milliseconds(400))
                    }), prompt: Text(verbatim: "https://…/v1")) { EmptyView() }
                    .labelsHidden()
                    .textFieldStyle(.prism)
                    .frame(width: 280)
                } label: {
                    Text(verbatim: "API Base URL").font(.system(size: 12, weight: .semibold)).foregroundStyle(PrismTheme.text)
                }
            }
            if !keyConfigured {
                APIKeyRow(service: service, provider: settings.provider)
            }
        }
    }

    private var xai: some View {
        VStack(alignment: .leading, spacing: 12) {
            DictationNote(Text("xAI's /stt endpoint picks the transcription model on the server. It has no model selection API.", bundle: .module))
            Button { choose("grok-stt") } label: { Text("Use This Provider", bundle: .module) }
                .buttonStyle(.prismPrimary)
                .keyboardShortcut(.defaultAction)
            if !keyConfigured {
                PrismHairline()
                APIKeyRow(service: service, provider: .xai)
            }
            Spacer()
        }
        .padding(.top, 8)
    }

    private func note(_ text: Text, systemImage: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage).font(.system(size: 18)).foregroundStyle(PrismTheme.textMuted)
            text.font(.system(size: 12)).foregroundStyle(PrismTheme.textSecondary).multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load() async {
        guard canLoad else { catalog = nil; return }
        loading = true
        error = nil
        defer { loading = false }
        if settings.provider == .custom { try? await Task.sleep(for: .milliseconds(350)) }
        guard !Task.isCancelled else { return }
        let provider = settings.provider
        let baseURL = settings.baseURL
        let keys = service.keys
        do {
            let apiKey = provider == .vercel ? nil : try await Task.detached { try keys.key(for: provider) }.value
            let result = try await SpeechModelCatalog.load(provider: provider, baseURL: baseURL, apiKey: apiKey)
            guard !Task.isCancelled else { return }
            catalog = result
        } catch {
            guard !Task.isCancelled else { return }
            catalog = nil
            self.error = error.localizedDescription
        }
    }

    private func move(_ offset: Int) {
        let rows = filtered.filter(\.batchCompatible)
        guard !rows.isEmpty else { return }
        let index = rows.firstIndex { $0.id == selection } ?? (offset > 0 ? -1 : rows.count)
        selection = rows[min(max(index + offset, 0), rows.count - 1)].id
    }

    private func selectable(_ id: String?) -> Bool {
        guard let id else { return false }
        return filtered.contains { $0.id == id && $0.batchCompatible }
    }

    private func chooseSelection() {
        if selectable(selection), let selection { choose(selection) } else if let first = filtered.first(where: \.batchCompatible), !query.isEmpty { choose(first.id) }
    }

    private func choose(_ model: String) {
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return }
        var next = service.settings
        next.model = model
        if next.baseURL.isEmpty { next.baseURL = next.provider.fixedBaseURL ?? "" }
        service.update(next)
        if service.flush() { onChosen() }
    }
}

private struct SpeechModelRow: View {
    let model: SpeechModel
    let selected: Bool

    var body: some View {
        HStack {
            Text(verbatim: model.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(PrismTheme.text)
            Spacer(minLength: 8)
            if selected { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(PrismTheme.accent) }
        }
        Text(verbatim: model.ownedBy.isEmpty ? model.id : "\(model.id) · \(model.ownedBy)")
            .font(.system(size: 11)).foregroundStyle(PrismTheme.textSecondary).lineLimit(1).truncationMode(.middle)
        if !model.description.isEmpty {
            Text(verbatim: model.description)
                .font(.system(size: 12)).foregroundStyle(PrismTheme.textSecondary).lineSpacing(3).lineLimit(2)
        }
        Text(verbatim: model.unavailableReason ?? model.priceText)
            .font(.system(size: 11))
            .foregroundStyle(model.batchCompatible ? PrismTheme.textMuted : PrismTheme.warning)
    }
}

// MARK: Local

private struct LocalModelList: View {
    let service: DictationService
    let onChosen: () -> Void
    @ViewState private var busy: String?
    @ViewState private var error: String?
    @ViewState private var notice: String?
    @ViewState private var modelPath = ""
    @ViewState private var whisperPath = ""

    private var manager: LocalModelManager { service.localModels }
    private var settings: DictationSettings { service.settings }
    private var locked: Bool { busy != nil || manager.download != nil || manager.installingEngine || manager.verifying != nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                DictationNote(Text("Download once to transcribe on this Mac. Local speech recognition needs no API key and does not upload audio.", bundle: .module))
                engine
                VStack(spacing: 6) {
                    ForEach(LocalModel.all) { model in
                        row(model)
                    }
                }
                if let download = manager.download, let model = LocalModel.find(download.modelID) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(verbatim: model.name).font(.system(size: 12, weight: .semibold))
                        ProgressView(value: Double(download.downloaded), total: Double(download.total))
                            .progressViewStyle(.linear)
                            .tint(PrismTheme.accent)
                        HStack {
                            Text(verbatim: "\(LocalModel.sizeText(download.downloaded)) / \(LocalModel.sizeText(download.total))")
                                .font(.system(size: 11)).foregroundStyle(PrismTheme.textMuted).monospacedDigit()
                            Spacer()
                            Button { manager.cancelDownload() } label: { Text("Cancel Download", bundle: .module) }.buttonStyle(.prism)
                        }
                    }
                }
                if let notice { DictationNote(Text(verbatim: notice)) }
                if let error { DictationNote(Text(verbatim: error), tone: .warning) }
                advanced
            }
            .padding(.vertical, 2)
        }
        .onAppear {
            modelPath = settings.modelPath
            whisperPath = settings.whisperPath
            manager.refresh(preferredWhisperPath: settings.whisperPath)
        }
    }

    /// `.dictation-engine-status`: whether whisper.cpp is ready, with install and re-check actions.
    private var engine: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(manager.whisperPath != nil ? PrismTheme.success : PrismTheme.warning)
                .frame(width: 6, height: 6)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 4) {
                Text(manager.whisperPath != nil ? "Speech engine ready" : "Speech engine required", bundle: .module)
                    .font(.system(size: 12, weight: .semibold))
                if let path = manager.whisperPath {
                    Text(verbatim: path).font(.system(size: 11)).foregroundStyle(PrismTheme.textSecondary).lineLimit(1).truncationMode(.middle)
                } else {
                    Text(manager.canInstallEngine ? "Install whisper.cpp with your existing Homebrew. This also installs its required dependencies."
                                                  : "Install Homebrew or choose an existing whisper-cli in Advanced settings.", bundle: .module)
                        .font(.system(size: 11)).foregroundStyle(PrismTheme.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if manager.whisperPath == nil {
                if manager.canInstallEngine {
                    Button(action: installEngine) {
                        Text(manager.installingEngine ? "Installing speech engine…" : "Install Speech Engine", bundle: .module)
                    }
                    .buttonStyle(.prism)
                    .disabled(locked)
                }
                Button { manager.refresh(preferredWhisperPath: whisperPath) } label: { Text("Check Again", bundle: .module) }
                    .buttonStyle(.prism)
                    .disabled(manager.installingEngine)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(PrismTheme.line))
    }

    private func row(_ model: LocalModel) -> some View {
        let path = manager.installed[model.id]
        let selected = path != nil && path == settings.modelPath
        return ModelCard(selected: selected, highlighted: false, action: { select(model) }) {
            HStack {
                Text(verbatim: model.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(PrismTheme.text)
                Spacer(minLength: 8)
                if selected {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(PrismTheme.accent)
                } else if path == nil {
                    Image(systemName: "arrow.down.to.line").font(.system(size: 11, weight: .medium)).foregroundStyle(PrismTheme.textMuted)
                }
            }
            Text(verbatim: model.localizedDescription)
                .font(.system(size: 12)).foregroundStyle(PrismTheme.textSecondary).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: "\(LocalModel.sizeText(model.bytes)) · \(status(model, path: path, selected: selected))")
                .font(.system(size: 11)).foregroundStyle(PrismTheme.textMuted)
        }
        .disabled(locked)
    }

    private func status(_ model: LocalModel, path: String?, selected: Bool) -> String {
        if busy == model.id || manager.verifying == model.id { return String(localized: "Preparing model…", bundle: .module) }
        if selected { return String(localized: "Selected", bundle: .module) }
        return path != nil ? String(localized: "Use model", bundle: .module) : String(localized: "Download and use", bundle: .module)
    }

    private var advanced: some View {
        PrismDisclosure(Text("Advanced · use existing files", bundle: .module)) {
            VStack(alignment: .leading, spacing: 8) {
                DictationNote(Text("Existing Whisp models and custom whisper.cpp files are used in place, without changes.", bundle: .module))
                pathField(Text("Local model file", bundle: .module), text: $modelPath, placeholder: "ggml-model.bin", directory: false)
                pathField(Text(verbatim: "whisper.cpp"), text: $whisperPath, placeholder: DictationSettings.defaultWhisperPath, directory: false)
                HStack {
                    Spacer()
                    Button(action: useFiles) { Text("Use Local Model", bundle: .module) }
                        .buttonStyle(.prism)
                        .disabled(modelPath.isEmpty || whisperPath.isEmpty || locked)
                }
            }
            .padding(.leading, 15)
        }
        .padding(.vertical, 6)
    }

    private func pathField(_ label: Text, text: Binding<String>, placeholder: String, directory: Bool) -> some View {
        HStack(spacing: 6) {
            label.font(.system(size: 12)).foregroundStyle(PrismTheme.text).frame(width: 110, alignment: .leading)
            TextField(text: text, prompt: Text(verbatim: placeholder)) { EmptyView() }
                .labelsHidden()
                .textFieldStyle(.prism)
            Button {
                let panel = NSOpenPanel()
                panel.canChooseFiles = true
                panel.canChooseDirectories = directory
                panel.allowsMultipleSelection = false
                panel.showsHiddenFiles = false
                if !text.wrappedValue.isEmpty { panel.directoryURL = URL(filePath: text.wrappedValue).deletingLastPathComponent() }
                if panel.runModal() == .OK, let url = panel.url { text.wrappedValue = url.path }
            } label: { Image(systemName: "folder").font(.system(size: 12)) }
            .buttonStyle(.prism)
            .help(Text("Choose File…", bundle: .module))
        }
    }

    private func select(_ model: LocalModel) {
        guard !locked else { return }
        busy = model.id
        error = nil
        notice = nil
        Task {
            defer { busy = nil }
            do {
                let path = try await manager.prepare(model)
                manager.refresh(preferredWhisperPath: settings.whisperPath)
                guard let whisper = manager.whisperPath else {
                    notice = String(localized: "Model downloaded. Install the speech engine, then select the model to use it.", bundle: .module)
                    return
                }
                var next = service.settings
                next.provider = .local
                next.baseURL = ""
                next.model = model.name
                next.modelPath = path
                next.whisperPath = whisper
                service.update(next)
                if service.flush() { onChosen() }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func installEngine() {
        busy = "engine"
        error = nil
        Task {
            defer { busy = nil }
            do {
                whisperPath = try await manager.installEngine()
                notice = String(localized: "Speech engine ready. Select a model to use it.", bundle: .module)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func useFiles() {
        var next = service.settings
        next.provider = .local
        next.baseURL = ""
        next.model = ""
        next.modelPath = modelPath.trimmingCharacters(in: .whitespaces)
        next.whisperPath = whisperPath.trimmingCharacters(in: .whitespaces)
        service.update(next)
        if service.flush() { onChosen() } else if case .failed(let message) = service.saveState { error = message }
    }
}
