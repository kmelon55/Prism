import PrismKit
import SwiftUI

struct ClipboardNotchView: View {
    @Bindable var model: ClipboardHistoryModel
    let dismiss: () -> Void
    @ViewState private var copiedID: Int64?
    @ViewState private var copyError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(ClipboardText.localize("Search clipboard"), text: $model.query)
                        .textFieldStyle(.plain).font(.system(size: 12))
                    if !model.query.isEmpty {
                        Button { model.query = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }.buttonStyle(.plain).accessibilityLabel(ClipboardText.localize("Clear search"))
                    }
                }.padding(.horizontal, 11).frame(height: 32)
                    .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
                NotchIconButton("arrow.up.right", label: ClipboardText.localize("Open Clipboard History")) {
                    dismiss()
                    if let context = model.history.context { context.showPalette(screen: ClipboardFeature.historyScreen(context: context)) }
                }
            }
            if let error = copyError ?? model.errorMessage {
                Text(error).foregroundStyle(.red).font(.system(size: 11))
            }
            if !model.hasLoaded {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !model.isEnabled {
                VStack(spacing: 10) {
                    NotchEmptyState("clipboard", title: ClipboardText.localize("Clipboard history is off"))
                    Button(ClipboardText.localize("Clipboard Settings")) {
                        dismiss()
                        model.history.context?.openSettings(paneID: ClipboardFeature.settingsPaneID)
                    }.foregroundStyle(.orange)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.entries.isEmpty {
                NotchEmptyState("doc.on.clipboard", title: ClipboardText.localize("No clipboard entries"))
            } else {
                ScrollView {
                    LazyVStack(spacing: 5) {
                        ForEach(model.entries.prefix(30)) { entry in
                            Button {
                                Task {
                                    do {
                                        try await model.history.copy(id: entry.id)
                                        copiedID = entry.id
                                        copyError = nil
                                    } catch { copyError = error.localizedDescription }
                                }
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: symbol(entry.kind)).font(.system(size: 13))
                                        .foregroundStyle(.orange.opacity(0.85)).frame(width: 28, height: 30)
                                        .background(.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
                                    Text(verbatim: entry.text).font(.system(size: 11)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                    Image(systemName: copiedID == entry.id ? "checkmark" : "doc.on.doc")
                                        .foregroundStyle(copiedID == entry.id ? .green : .white.opacity(0.4))
                                }
                                .padding(.horizontal, 9).padding(.vertical, 8)
                            }
                            .buttonStyle(NotchButtonStyle(selected: copiedID == entry.id))
                            .help(ClipboardText.localize("Copy to Clipboard"))
                        }
                    }
                }
            }
        }
        .task { model.load() }
        .onReceive(NotificationCenter.default.publisher(for: ClipboardHistory.didChange)) { _ in model.refresh() }
    }

    private func symbol(_ kind: ClipboardKind) -> String {
        switch kind { case .text: "text.alignleft"; case .image: "photo"; case .files: "doc" }
    }
}
