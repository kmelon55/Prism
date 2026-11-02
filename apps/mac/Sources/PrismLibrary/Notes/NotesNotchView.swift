import PrismKit
import SwiftUI

struct NotesNotchView: View {
    @Bindable var model: NotesModel
    let services: LibraryServices
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Menu {
                    ForEach(model.library.entries(of: [.note]).prefix(20)) { note in
                        Button(note.title) { Task { await model.select(note) } }
                    }
                } label: {
                    Text(model.document?.title.isEmpty == false ? (model.document?.title ?? "") : L10n.tr("Quick Note"))
                        .lineLimit(1).font(.system(size: 11, weight: .medium))
                }.menuStyle(.borderlessButton).frame(maxWidth: 260, alignment: .leading)
                Spacer()
                NotchIconButton("plus", label: L10n.tr("New Note")) {
                    Task { await model.select(nil) }
                }.disabled(model.isBusy)
                NotchIconButton("arrow.up.right", label: L10n.tr("Open Notes")) {
                    dismiss()
                    services.notes.show()
                }
            }
            ZStack(alignment: .topLeading) {
                if model.documentText.isEmpty {
                    Text(L10n.tr("Write something to remember…")).foregroundStyle(.secondary)
                        .padding(.horizontal, 12).padding(.top, 12).allowsHitTesting(false)
                }
                TextEditor(text: $model.documentText)
                    .scrollContentBackground(.hidden).font(.system(size: 12)).lineSpacing(4)
                    .padding(7)
                    .disabled(model.document == nil || model.isBusy)
                    .accessibilityLabel(L10n.tr("Note content"))
            }
            .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.065)))
            HStack(spacing: 5) {
                if let error = model.errorMessage ?? model.library.loadError {
                    Text(error).foregroundStyle(.red).lineLimit(1)
                    Button(L10n.tr("Retry")) { model.retrySave() }
                } else {
                    Image(systemName: model.status == .saved ? "checkmark.circle" : "circle.dotted")
                        .foregroundStyle(model.status == .saved ? .green.opacity(0.7) : .secondary)
                    Text(model.status == .saving ? L10n.tr("Saving…") : model.status == .saved ? L10n.tr("Saved") : L10n.tr("Saves to Notes"))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }.font(.system(size: 10))
        }
        .task { await model.openInitial(noteID: nil) }
    }
}
