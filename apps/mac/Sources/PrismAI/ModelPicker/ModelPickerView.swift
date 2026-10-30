import PrismKit
import SwiftUI

/// The searchable model catalog used by the composer (this conversation's model) and settings (default model).
/// Lists are fetched from the provider; search is local. Selecting a row saves immediately.
struct ModelPickerView: View {
    enum Purpose { case chat, settings, other(String) }

    let service: AIService
    let selection: AISelection
    var purpose: Purpose = .chat
    let onSelect: (AISelection) async throws -> Void
    var onSettings: (() -> Void)?
    var onDismiss: () -> Void = {}

    @ViewState private var provider: AIProvider = .vercel
    @ViewState private var models: [AIModel] = []
    @ViewState private var loading = false
    @ViewState private var error: String?
    @ViewState private var query = ""
    @ViewState private var sort: ModelSort = .name
    @ViewState private var limit = 40
    @ViewState private var highlighted: String?
    @ViewState private var saving: String?
    @ViewState private var revision = 0
    @FocusState private var searchFocused: Bool

    private var isChat: Bool {
        if case .chat = purpose { true } else { false }
    }

    private var title: String {
        switch purpose {
        case .chat: L("Model for this conversation")
        case .settings: L("Default model")
        case .other(let title): title
        }
    }

    private var filtered: [AIModel] {
        let search = ModelSearch(query)
        return sort.sorted(models.filter(search.matches))
    }

    var body: some View {
        PrismPickerPanel {
            PrismPickerHeader(Text(title),
                              count: loading ? nil : L("\(filtered.count) models"), refreshing: loading,
                              refreshDisabled: loading || saving != nil,
                              onRefresh: { revision += 1 }, onClose: onDismiss)
            PrismPillTabs(selection: $provider,
                          options: AIProvider.displayOrder.map { ($0, $0 == .vercel ? "Vercel" : $0.name) },
                          fontSize: 12, expands: true)
                .disabled(saving != nil)
                .accessibilityLabel(L("Model provider"))
            PrismSearchWell {
                TextField(text: $query, prompt: Text(L("Search model names…"))) { Text(L("Search model names…")) }
                    .labelsHidden()
                    .focused($searchFocused)
                    .onSubmit { selectHighlighted() }
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onChange(of: query) { limit = 40; highlighted = filtered.first?.id }
            }
            columns
            if let error {
                Text(verbatim: error)
                    .font(.system(size: 11))
                    .foregroundStyle(PrismTheme.danger)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            list
            footer
        }
        .frame(width: 640, height: 540)
        .onAppear {
            provider = selection.provider
            searchFocused = true
        }
        .task(id: "\(provider.rawValue)-\(revision)") { await load() }
    }

    private static let metricWidths: (price: CGFloat, speed: CGFloat) = (82, 86)

    private var columns: some View {
        HStack(spacing: 14) {
            sortButton(.name, title: L("Model")).frame(maxWidth: .infinity, alignment: .leading)
            sortButton(.input, title: L("Input")).frame(width: Self.metricWidths.price, alignment: .trailing)
            sortButton(.output, title: L("Output")).frame(width: Self.metricWidths.price, alignment: .trailing)
            Text(L("Reference speed")).lineLimit(1).minimumScaleFactor(0.8).frame(width: Self.metricWidths.speed, alignment: .trailing)
        }
        .font(.system(size: 11))
        .foregroundStyle(PrismTheme.textSecondary)
        .padding(.horizontal, 12)
    }

    private func sortButton(_ value: ModelSort, title: String) -> some View {
        Button {
            sort = value
            limit = 40
        } label: {
            Text(verbatim: title + (sort == value ? " ↑" : ""))
                .foregroundStyle(sort == value ? PrismTheme.accentStrong : PrismTheme.textSecondary)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filtered.prefix(limit)) { model in
                        row(model).id(model.id)
                    }
                    if filtered.count > limit {
                        Button { limit += 40 } label: {
                            Text(L("Show more · \(filtered.count - limit)"))
                                .font(.system(size: 12))
                                .foregroundStyle(PrismTheme.accentStrong)
                                .frame(maxWidth: .infinity)
                                .padding(12)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if loading {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(L("Loading models…")).font(.system(size: 12)).foregroundStyle(PrismTheme.textMuted)
                        }
                        .padding(12)
                    } else if error == nil, filtered.isEmpty {
                        Text(models.isEmpty ? (provider == .openai ? L("OpenAI loads models after you save an API key or allow key use.") : L("No text models are available.")) : L("No matching models."))
                            .font(.system(size: 11))
                            .foregroundStyle(PrismTheme.textMuted)
                            .padding(12)
                    }
                    if provider == .compatible, case let id = query.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty,
                       !filtered.contains(where: { $0.id == id }) {
                        Button(L("Use model ID: \(id)")) { choose(AIModel(id: id, name: id)) }
                            .buttonStyle(.prism)
                            .disabled(saving != nil || !AIRequest.isValidModelID(id))
                            .padding(12)
                    }
                }
            }
            .frame(minHeight: 0, maxHeight: .infinity)
            .layoutPriority(-1)
            .overlay(alignment: .top) { PrismHairline() }
            .overlay(alignment: .bottom) { PrismHairline() }
            .onChange(of: highlighted) { _, id in
                if let id { proxy.scrollTo(id) }
            }
        }
    }

    private func row(_ model: AIModel) -> some View {
        let selected = selection.provider == provider && selection.model == model.id
        let isHighlighted = highlighted == model.id
        return Button {
            choose(model)
        } label: {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(verbatim: model.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(PrismTheme.text).lineLimit(1)
                        if selected { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(PrismTheme.accent) }
                        if saving == model.id { ProgressView().controlSize(.mini) }
                    }
                    Text(verbatim: model.id).font(.system(size: 11)).foregroundStyle(PrismTheme.textSecondary).lineLimit(1).truncationMode(.middle)
                    capabilities(model)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                PriceCell(price: model.inputPrice, variable: model.pricingVariable).frame(width: Self.metricWidths.price, alignment: .trailing)
                PriceCell(price: model.outputPrice, variable: model.pricingVariable).frame(width: Self.metricWidths.price, alignment: .trailing)
                SpeedCell(entry: ModelSpeedReference.entry(model.id, provider: provider)).frame(width: Self.metricWidths.speed, alignment: .trailing)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(minHeight: 72)
            .background(PrismPickerRowBackground(highlighted: isHighlighted, selected: selected))
            .overlay(alignment: .bottom) { PrismHairline() }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(saving != nil)
        .onHover { if $0 { highlighted = model.id } }
        .accessibilityLabel(L("Use \(model.name)"))
    }

    @ViewBuilder
    private func capabilities(_ model: AIModel) -> some View {
        let chips = [
            model.contextWindow.map { L("\($0.formatted(.number.notation(.compactName))) context") },
            model.supportsImages == true ? L("Images") : nil,
            model.supportsTools == true ? L("Tools") : nil,
        ].compactMap { $0 }
        if !chips.isEmpty {
            HStack(spacing: 8) {
                ForEach(chips, id: \.self) { chip in
                    Text(verbatim: chip)
                }
            }
            .font(.system(size: 10))
            .foregroundStyle(PrismTheme.textMuted)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("USD / 1M tokens · More filled cells mean higher price or faster generation. — no data"))
                .font(.system(size: 10))
                .foregroundStyle(PrismTheme.textMuted)
                .help(L("Base rates from the provider API. * Rates vary by tier or route. Caching and other conditions are extra."))
            if provider == .openai {
                HStack(spacing: 4) {
                    Text(L("OpenAI's model list does not include prices."))
                    Link(destination: URL(string: "https://developers.openai.com/api/docs/pricing")!) {
                        HStack(spacing: 3) {
                            Text(L("Official pricing"))
                            Image(systemName: "arrow.up.right.square").font(.system(size: 9))
                        }
                        .foregroundStyle(PrismTheme.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
                .font(.system(size: 10))
                .foregroundStyle(PrismTheme.textMuted)
            }
            HStack(spacing: 12) {
                Text(isChat ? L("Keeps the conversation and applies from the next answer.") : L("Click a model to save it. Messages are billed by the selected provider."))
                    .font(.system(size: 11))
                    .foregroundStyle(PrismTheme.textSecondary)
                Spacer()
                if let onSettings {
                    Button(L("API keys & tools…")) {
                        onDismiss()
                        onSettings()
                    }
                    .buttonStyle(.prism)
                    .font(.system(size: 11))
                }
            }
            .padding(.top, 4)
        }
    }

    // MARK: Actions

    private func load() async {
        loading = true
        error = nil
        models = []
        defer { loading = false }
        do {
            let result = try await service.listModels(provider)
            guard !Task.isCancelled else { return }
            models = result
            highlighted = filtered.first?.id
        } catch is CancellationError {
        } catch {
            self.error = ChatModel.message(error)
        }
    }

    private func move(_ delta: Int) {
        let rows = Array(filtered.prefix(limit))
        guard !rows.isEmpty else { return }
        let index = rows.firstIndex { $0.id == highlighted } ?? (delta > 0 ? -1 : rows.count)
        highlighted = rows[(index + delta + rows.count) % rows.count].id
    }

    private func selectHighlighted() {
        guard let model = filtered.first(where: { $0.id == highlighted }) ?? filtered.first else { return }
        choose(model)
    }

    private func choose(_ model: AIModel) {
        guard saving == nil else { return }
        saving = model.id
        error = nil
        Task {
            defer { saving = nil }
            do {
                try await onSelect(AISelection(provider: provider, model: model.id, modelName: model.name))
                onDismiss()
            } catch {
                self.error = ChatModel.message(error)
            }
        }
    }
}

/// A price per million tokens with a five-step meter (`.model-metric`).
struct PriceCell: View {
    let price: Double?
    var variable = false

    var body: some View {
        let level = AIPrice.level(price)
        VStack(alignment: .trailing, spacing: 6) {
            Text(verbatim: level == nil ? "—" : AIPrice.format(price) + (variable ? "*" : ""))
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(PrismTheme.textSecondary)
            if let level { PrismMeter(level: level, kind: .price) }
        }
        .help(L("USD per 1M tokens · Price steps: $0 / <$0.1 / <$0.5 / <$2 / <$10 / $10+") + (variable ? L(" · Rates vary by tier or route") : ""))
    }
}

struct SpeedCell: View {
    let entry: ModelSpeedReference.Entry?

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Text(verbatim: entry.map { "\($0.tokens) t/s" } ?? "—")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(PrismTheme.textSecondary)
            if let entry { PrismMeter(level: ModelSpeedReference.level(entry), kind: .speed) }
        }
        .help(entry.map { "Vercel AI Gateway · \($0.route) · 2026-10-28 · " + L("First token") + " \($0.first)s · " + L("Actual response time varies by request and route.") }
              ?? L("No comparable public speed data."))
    }
}
