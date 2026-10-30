import AppKit
import PrismKit
import SwiftUI
import UniformTypeIdentifiers

/// The AI chat workspace inside the expanded palette, drawn after the Tauri `AiChat.tsx`: a quiet conversation
/// sidebar beside the thread with its header, transcript and composer card. Everything is monochrome and draws on
/// the palette glass, so the screen has no background of its own.
struct ChatRootView: View {
    @Bindable var model: ChatModel
    var onClose: () -> Void = {}
    var onExport: (ChatSession?) -> Void = { _ in }
    var chooseFolder: @MainActor () -> URL? = { nil }

    @ViewState private var dropTargeted = false
    /// The conversation being renamed inline under the header (`.ai-rename`).
    @ViewState private var renaming: ChatSession?
    /// Drives the opening motion (`ai-phase-opening`): the sidebar slides in, the thread rises.
    @ViewState private var arrived = ChatMotion.reduce

    var body: some View {
        HStack(spacing: 0) {
            ChatSidebar(model: model, onClose: close, onExport: onExport, onRename: { renaming = $0 })
                .frame(width: ChatMetrics.sidebarWidth)
                .frame(maxHeight: .infinity)
                .background(ChatColors.inset)
                .overlay(alignment: .trailing) { Rectangle().fill(PrismTheme.line).frame(width: 1) }
                .opacity(arrived ? 1 : 0)
                .offset(x: arrived ? 0 : -12)
            ZStack {
                ConversationView(model: model, renaming: $renaming, onEscape: handleEscape, onExport: onExport, chooseFolder: chooseFolder)
                    .id(model.current.id)
                    .transition(ChatMotion.reduce ? .identity : .asymmetric(
                        insertion: .opacity.combined(with: .offset(y: 8)).animation(ChatMotion.ease.delay(0.06)),
                        removal: .opacity.combined(with: .offset(y: -4)).animation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.1))))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .opacity(arrived ? 1 : 0)
            .offset(y: arrived ? 0 : 9)
            .animation(ChatMotion.reduce ? nil : ChatMotion.ease, value: model.current.id)
        }
        .onAppear {
            guard !arrived else { return }
            withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.34)) { arrived = true }
        }
        .onChange(of: model.current.id) { renaming = nil }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            loadDroppedFiles(providers)
            return true
        }
        .overlay {
            if dropTargeted {
                // `.ai-image-drop-hint`
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(ChatColors.shell.opacity(0.92))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(PrismTheme.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4])))
                    .overlay(Text(L("Drop an image to attach it")).font(.system(size: 14)).foregroundStyle(PrismTheme.text))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            if let target = model.deleteTarget {
                DeleteDialog(model: model, target: target)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.14), value: model.deleteTarget?.id)
        .background(hiddenShortcuts)
        .onExitCommand(perform: handleEscape)
    }

    /// Escape closes the innermost layer first: the delete dialog, then inline rename, then the chat itself.
    private func handleEscape() {
        if model.deleteTarget != nil {
            if !model.switching { model.deleteTarget = nil }
        } else if renaming != nil {
            renaming = nil
        } else {
            close()
        }
    }

    private func close() {
        onClose()
    }

    /// ⌘N and ⌘1–⌘9 work anywhere in the window without visible hints.
    private var hiddenShortcuts: some View {
        ZStack {
            Button("") { model.newConversation() }.keyboardShortcut("n", modifiers: .command)
            ForEach(1..<10, id: \.self) { number in
                Button("") { model.selectVisible(number - 1) }
                    .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: .command)
            }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private func loadDroppedFiles(_ providers: [NSItemProvider]) {
        let group = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !group.isEmpty else { return }
        if group.count != 1 {
            model.setError(L("Drop one image at a time."))
            return
        }
        _ = group[0].loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in model.attachImage(from: [url]) }
        }
    }
}

// MARK: Tokens

/// Layout values from the Tauri `.ai-*` rules.
enum ChatMetrics {
    static let sidebarWidth: CGFloat = 228
    static let messageWidth: CGFloat = 760
}

/// Colors the chat needs beyond `PrismTheme`, from `surfaces.css`.
enum ChatColors {
    /// `--inset`: the sidebar sits a shade darker than the thread.
    static let inset = PrismTheme.dynamic(dark: 0x000000, darkAlpha: 0x07, light: 0x000000, lightAlpha: 0x03)
    /// `--shell` at full strength, for the dialog and the jump pill that float over content.
    static let shell = Color(nsColor: PrismTheme.shellTint(opacity: 1))
    /// The composer card: a raised opaque panel, a step lighter than `--panel` as in the reference capture.
    static let composer = PrismTheme.dynamic(dark: 0x313131, light: 0xFFFFFF)
    /// The Send button: a silver gradient in dark mode (`.ai-send`), a graphite one in light mode.
    static let sendTop = PrismTheme.dynamic(dark: 0xE2E2E2, light: 0x3A3A3A)
    static let sendBottom = PrismTheme.dynamic(dark: 0xCFCFCF, light: 0x242424)
    static let sendText = PrismTheme.dynamic(dark: 0x07111B, light: 0xF6F6F6)
    static let sendBorder = PrismTheme.dynamic(dark: 0xDEDEDE, light: 0x242424)
}

enum ChatMotion {
    static var reduce: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// `--ai-ease` over 240 ms.
    static let ease = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.24)
}

/// A borderless chat button (`.ai-chat button`): an optional resting fill, `--surface-selected` on hover,
/// 40 % opacity when disabled and a 1 pt press nudge.
struct ChatButtonStyle: ButtonStyle {
    var fill: Color = .clear
    var stroke: Color = .clear
    var radius: CGFloat = 6

    func makeBody(configuration: Configuration) -> some View {
        ChatButtonBody(configuration: configuration, fill: fill, stroke: stroke, radius: radius)
    }
}

private struct ChatButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let fill: Color
    let stroke: Color
    let radius: CGFloat
    @Environment(\.isEnabled) private var isEnabled
    @ViewState private var hovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        configuration.label
            .background(shape.fill(hovered && isEnabled ? PrismTheme.surfaceSelected : fill))
            .overlay(shape.strokeBorder(stroke))
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.4)
            .offset(y: configuration.isPressed && isEnabled && !ChatMotion.reduce ? 1 : 0)
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: 0.14), value: hovered)
    }
}

/// `.ai-icon-button`: a 7 pt padded glyph.
private struct ChatIconButton: View {
    let systemImage: String
    var size: CGFloat = 13
    let label: String
    var pressed = false
    var tint: Color = PrismTheme.textSecondary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size, weight: .regular))
                .foregroundStyle(pressed ? PrismTheme.accent : tint)
                .frame(width: 15, height: 15)
                .padding(7)
        }
        .buttonStyle(ChatButtonStyle(fill: pressed ? PrismTheme.surfaceSelected : .clear))
        .help(label)
        .accessibilityLabel(label)
    }
}

/// CSS line heights: SwiftUI spaces lines with `lineSpacing` and adds the half-leading above and below.
private struct LineHeight: ViewModifier {
    let size: CGFloat
    let multiple: CGFloat

    func body(content: Content) -> some View {
        let natural = NSFont.systemFont(ofSize: size).boundingRectForFont.height * 0.83
        let extra = max(0, size * multiple - natural)
        content
            .lineSpacing(extra)
            .padding(.vertical, extra / 2)
    }
}

extension View {
    func chatLineHeight(_ size: CGFloat, _ multiple: CGFloat) -> some View {
        modifier(LineHeight(size: size, multiple: multiple))
    }
}

// MARK: Sidebar

private struct ChatSidebar: View {
    @Bindable var model: ChatModel
    let onClose: () -> Void
    let onExport: (ChatSession?) -> Void
    let onRename: (ChatSession) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // `.ai-sidebar-heading`
            HStack(spacing: 8) {
                ChatIconButton(systemImage: "arrow.left", size: 14, label: L("Back to commands"), tint: PrismTheme.text, action: onClose)
                Text(L("AI Chat"))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(PrismTheme.text)
                Spacer(minLength: 0)
                Image(systemName: "sparkles")
                    .font(.system(size: 13))
                    .foregroundStyle(PrismTheme.accent)
                    .padding(.trailing, 4)
            }
            .padding(.horizontal, 3)
            .padding(.bottom, 14)

            // `.ai-new-session`
            Button { model.newConversation() } label: {
                HStack(spacing: 7) {
                    Image(systemName: "plus").font(.system(size: 13))
                    Text(L("New conversation"))
                    Spacer(minLength: 0)
                }
                .font(.system(size: 12))
                .foregroundStyle(PrismTheme.text)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(ChatButtonStyle(fill: PrismTheme.surfaceSelected, stroke: PrismTheme.lineStrong, radius: 7))
            .disabled(model.switching || !model.historyReady)
            .help(L("New conversation") + " (⌘N)")

            // `.ai-history-search`
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11))
                TextField(text: $model.filter, prompt: Text(L("Search conversations")).foregroundStyle(PrismTheme.textMuted)) {
                    Text(L("Search conversations"))
                }
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(PrismTheme.text)
            }
            .foregroundStyle(PrismTheme.textMuted)
            .padding(.horizontal, 6)
            .padding(.top, 14)
            .padding(.bottom, 10)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(model.filteredSessions) { session in
                        SessionRow(session: session, active: session.id == model.current.id, running: model.isRunning(session.id),
                                   disabled: model.switching, select: { if session.id != model.current.id { model.select(session.id) } },
                                   delete: { model.confirmDelete(session) })
                            .contextMenu { menu(for: session) }
                    }
                    if model.filteredSessions.isEmpty {
                        Text(!model.filter.isEmpty ? L("No results.") : model.historyReady ? L("Your conversations will appear here.") : L("Loading conversations…"))
                            .font(.system(size: 11))
                            .foregroundStyle(PrismTheme.textMuted)
                            .chatLineHeight(11, 1.7)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(10)
                    }
                }
            }
            .scrollIndicators(.never)
            .frame(maxHeight: .infinity)

            // `.ai-history-footer`
            Button { model.openSettings() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "key").font(.system(size: 12))
                    Text(L("AI settings")).font(.system(size: 12))
                }
                .foregroundStyle(PrismTheme.textSecondary)
                .padding(6)
            }
            .buttonStyle(ChatButtonStyle())
            .disabled(model.busy)
            .help(L("AI connection settings"))
            .padding(.horizontal, 5)
            .padding(.top, 12)
        }
        .padding(.top, 14)
        .padding(.horizontal, 10)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private func menu(for session: ChatSession) -> some View {
        Button(L("Rename…")) {
            if session.id != model.current.id { model.select(session.id) }
            onRename(session)
        }
        Button(session.pinned ? L("Unpin") : L("Pin")) { model.setPinned(!session.pinned, for: session.id) }
        Button(L("Export as Markdown…")) { onExport(session) }
        Divider()
        Button(L("Delete…"), role: .destructive) { model.confirmDelete(session) }
            .disabled(model.isRunning(session.id))
    }
}

/// `.ai-session`: icon, title and model; the selected row carries the selection gradient and a 2 pt edge.
private struct SessionRow: View {
    let session: ChatSession
    let active: Bool
    let running: Bool
    let disabled: Bool
    let select: () -> Void
    let delete: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        Button(action: select) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: session.pinned ? "pin" : "message")
                    .font(.system(size: 12))
                    .foregroundStyle(active ? PrismTheme.accent : PrismTheme.textMuted)
                    .frame(width: 14, height: 14)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 5) {
                    Text(verbatim: session.displayTitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(PrismTheme.text)
                        .lineLimit(1)
                    Text(verbatim: running ? L("Writing a reply…") : (session.modelLabel.isEmpty ? session.provider.name : session.modelLabel))
                        .font(.system(size: 10))
                        .foregroundStyle(PrismTheme.textMuted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 9)
            .padding(.trailing, 32)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, minHeight: 57, alignment: .topLeading)
            .background {
                if active {
                    RoundedRectangle(cornerRadius: 7, style: .continuous).fill(PrismTheme.selection)
                        .overlay(alignment: .leading) { Rectangle().fill(PrismTheme.accent).frame(width: 2) }
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
            }
        }
        .buttonStyle(ChatButtonStyle(radius: 7))
        .disabled(disabled)
        .overlay(alignment: .topTrailing) {
            ChatIconButton(systemImage: "trash", size: 11, label: L("Delete conversation"), tint: PrismTheme.textMuted, action: delete)
                .disabled(running || disabled)
                .help(running ? L("Stop this reply before deleting the conversation.") : L("Delete conversation"))
                .padding(.top, 8)
                .padding(.trailing, 3)
                .opacity(hovering ? 1 : 0)
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.16), value: active)
    }
}

// MARK: Conversation

private struct ConversationView: View {
    @Bindable var model: ChatModel
    @Binding var renaming: ChatSession?
    let onEscape: () -> Void
    let onExport: (ChatSession?) -> Void
    let chooseFolder: @MainActor () -> URL?

    @ViewState private var composerHeight: CGFloat = ComposerTextView.minHeight
    @ViewState private var following = true
    @ViewState private var showingModelPicker = false

    private var request: ChatRequestState { model.activeRequest }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let target = renaming {
                RenameRow(title: target.title, saving: model.switching, cancel: { renaming = nil }) { title in
                    if await model.rename(title, for: target.id) { renaming = nil }
                }
            }
            messages
            feedback
            composer
        }
        .overlay(alignment: .bottomLeading) {
            // `.ai-notice` sits under the composer without moving it.
            if let notice = model.notice {
                Text(verbatim: notice)
                    .font(.system(size: 12))
                    .foregroundStyle(PrismTheme.textMuted)
                    .lineLimit(1)
                    .padding(.leading, 26)
                    .padding(.bottom, 3)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: model.notice)
        .onAppear { model.load() }
    }

    // MARK: Header

    private var title: String {
        model.hasSavedSession || !model.current.messages.isEmpty || !model.current.draft.isEmpty ? model.current.displayTitle : L("New conversation")
    }

    private var subtitle: String {
        let label = model.current.modelLabel.isEmpty ? L("Choose a model") : model.current.modelLabel
        return "\(label) · \(model.current.provider.name)"
    }

    /// `.ai-header`: title and model over a faint surface, with rename, pin, export and delete.
    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 5) {
                Text(verbatim: title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(PrismTheme.text)
                    .lineLimit(1)
                Text(verbatim: subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(PrismTheme.textMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            ChatIconButton(systemImage: "pencil", size: 14, label: L("Rename"), tint: PrismTheme.text) { renaming = model.current }
                .disabled(model.busy || model.switching)
            ChatIconButton(systemImage: "pin", label: model.current.pinned ? L("Unpin") : L("Pin"), pressed: model.current.pinned, tint: PrismTheme.text) {
                model.setPinned(!model.current.pinned)
            }
            .disabled(model.busy || model.switching || !model.hasSavedSession)
            ChatIconButton(systemImage: "arrow.down.to.line", label: L("Export Markdown"), tint: PrismTheme.text) { onExport(nil) }
                .disabled(model.busy)
            ChatIconButton(systemImage: "trash", size: 13.5, label: L("Delete conversation"), tint: PrismTheme.text) { model.confirmDelete() }
                .help(model.busy ? L("Stop this reply before deleting the conversation.") : L("Delete conversation"))
                .disabled(model.busy || model.switching || (!model.hasSavedSession && model.current.isEmpty))
        }
        .padding(.leading, 26)
        .padding(.trailing, 25)
        .padding(.vertical, 12)
        .frame(minHeight: 66)
        .background(PrismTheme.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(PrismTheme.line).frame(height: 1) }
    }

    // MARK: Messages

    @ViewBuilder
    private var messages: some View {
        let display = model.displayMessages
        if display.isEmpty && !request.isRunning {
            WelcomeView(model: model)
                .padding(.horizontal, 36)
                .padding(.top, 24)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            transcript(display)
        }
    }

    private func transcript(_ display: [ChatTurn]) -> some View {
        let offset = max(0, display.count - model.visibleMessageCount)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    TranscriptRows(model: model, display: display, offset: offset) { following = false }
                    Color.clear.frame(height: 1).id("bottom")
                        .onAppear { following = true }
                        .onDisappear { following = false }
                }
                .padding(.horizontal, 36)
                .padding(.top, 24)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: display.last?.content) {
                if following { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: model.current.id) {
                following = true
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .overlay(alignment: .bottom) {
                if !following && !display.isEmpty {
                    // `.ai-jump-latest`
                    Button {
                        following = true
                        withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.down").font(.system(size: 11))
                            Text(L("Latest message"))
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(PrismTheme.text)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(ChatButtonStyle(fill: ChatColors.shell, stroke: PrismTheme.lineStrong, radius: 20))
                    .help(L("Jump to latest message"))
                    .padding(.bottom, 10)
                    .transition(.opacity)
                }
            }
        }
    }

    // MARK: Feedback

    @ViewBuilder
    private var feedback: some View {
        if !request.error.isEmpty {
            ErrorBanner(message: request.error, canRetry: !model.busy && model.canSend, retry: model.retry, settings: model.openSettings)
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
                .transition(.opacity.combined(with: .offset(y: 9)))
        }
        if model.failedEntry != nil {
            NoticeRow(text: L("Your new draft is waiting until the current conversation can be saved."), action: L("Open new draft")) { model.retryFailedEntry() }
                .disabled(model.switching)
        }
        if let error = model.historyError {
            NoticeRow(text: error, action: L("Retry saving or loading history"), isError: true) { model.retryHistory() }
        }
        if !model.current.messages.isEmpty && !model.configured && !model.checking {
            // `.ai-session-model-note`
            HStack(spacing: 8) {
                Text(L("Connect this provider's API key to keep chatting."))
                SmallButton(title: L("Open AI settings"), action: model.openSettings)
                Spacer(minLength: 0)
            }
            .font(.system(size: 11))
            .foregroundStyle(PrismTheme.textSecondary)
            .padding(.horizontal, 24)
            .padding(.vertical, 9)
            .overlay(alignment: .bottom) { Rectangle().fill(PrismTheme.line).frame(height: 1) }
        }
        if model.useFiles {
            // `.ai-context-hint`
            HStack(spacing: 5) {
                Image(systemName: "folder").font(.system(size: 10))
                Text(model.toolSettings.folders.count == 1 ? L("1 permitted folder · Read content is sent to AI")
                     : L("\(model.toolSettings.folders.count) permitted folders · Read content is sent to AI"))
                Spacer(minLength: 0)
            }
            .font(.system(size: 10))
            .foregroundStyle(PrismTheme.textMuted)
            .padding(.horizontal, 26)
            .padding(.bottom, 8)
        }
        if model.imageUnsupported && model.hasImages {
            Text(L("This model does not support images. Choose an image-capable model."))
                .font(.system(size: 12))
                .foregroundStyle(PrismTheme.danger)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 26)
                .padding(.bottom, 8)
        }
    }

    // MARK: Composer

    /// `.ai-composer`: an opaque card with the text, then model, capture, files and options beside Send.
    private var composer: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let image = model.current.draftImage, !model.busy {
                AttachmentPreview(image: image, remove: model.removeDraftImage)
                    .disabled(model.capturing || model.switching)
                    .padding(.bottom, 10)
            }
            ComposerTextView(
                text: Binding(get: { model.busy ? "" : model.current.draft }, set: { model.updateDraft($0) }),
                height: $composerHeight,
                placeholder: L("Ask a question…"),
                isEnabled: !model.busy && !model.capturing && model.historyReady && !model.switching && model.deleteTarget == nil,
                focusToken: model.focusToken,
                onSubmit: { model.send() },
                onEscape: onEscape,
                onPasteImage: { model.attachImage(data: $0) }
            )
            .frame(height: composerHeight)
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    modelChip
                    ChatIconButton(systemImage: "viewfinder", size: 14, label: L("Capture screen region"), tint: PrismTheme.textSecondary) {
                        model.captureScreenRegion()
                    }
                    .disabled(model.busy || model.capturing || model.switching || !model.historyReady || model.imageUnsupported)
                    FilesChip(on: model.useFiles) { model.toggleFiles(chooseFolder: chooseFolder) }
                        .disabled(model.busy || model.filesBusy)
                        .help(model.toolSettings.localFiles ? L("Send text from permitted folders to AI") : L("Choose a folder AI can read"))
                    ChatIconButton(systemImage: "slider.horizontal.3", size: 12.5, label: L("AI tool settings"), tint: PrismTheme.textSecondary) {
                        model.openSettings()
                    }
                    .disabled(model.busy)
                }
                Spacer(minLength: 0)
                sendButton
            }
            .padding(.top, 10)
        }
        .padding(.top, 14)
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(ChatColors.composer))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(PrismTheme.lineStrong))
        .overlay(
            // `--raised-shadow`: a hairline of light along the top edge.
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(LinearGradient(stops: [.init(color: .white.opacity(0.035), location: 0), .init(color: .clear, location: 0.06)],
                                             startPoint: .top, endPoint: .bottom))
                .allowsHitTesting(false)
        )
        .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
    }

    /// `.ai-model-trigger`
    private var modelChip: some View {
        Button {
            showingModelPicker.toggle()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "sparkles").font(.system(size: 12))
                Text(verbatim: model.current.modelLabel.isEmpty ? L("Choose model") : model.current.modelLabel)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .medium))
            }
            .font(.system(size: 11))
            .foregroundStyle(PrismTheme.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: 245, alignment: .leading)
            .fixedSize()
        }
        .buttonStyle(ChatButtonStyle(radius: 7))
        .disabled(model.busy || model.capturing || !model.historyReady)
        .help(L("Change conversation model"))
        .accessibilityLabel(L("Change conversation model"))
        .sheet(isPresented: $showingModelPicker) {
            ModelPickerView(service: model.service, selection: model.current.selection, purpose: .chat,
                            onSelect: { try await model.changeModel($0) }, onSettings: model.openSettings,
                            onDismiss: { showingModelPicker = false })
        }
    }

    /// `.ai-send`: "Send ↑", or "■ Stop" while a reply streams.
    @ViewBuilder
    private var sendButton: some View {
        if model.busy {
            Button { model.cancel() } label: {
                HStack(spacing: 9) {
                    Image(systemName: "stop.fill").font(.system(size: 10))
                    Text(L("Stop"))
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(PrismTheme.text)
                .padding(.horizontal, 12)
                .frame(minHeight: 34)
            }
            .buttonStyle(ChatButtonStyle(fill: PrismTheme.surfaceStrong, stroke: PrismTheme.lineStrong, radius: 10))
            .disabled(request.pending.isEmpty || request.cancelled)
            .help(L("Stop the reply"))
            .accessibilityLabel(L("Stop response"))
        } else {
            SendButton(enabled: model.canSend) { model.send() }
                .disabled(!model.canSend)
                .help(model.activeCount >= AIRequestRegistry.limit ? L("Up to three conversations can reply at once. Wait for a reply or stop one.") : L("Send"))
                .accessibilityLabel(L("Send message"))
        }
    }
}

private struct SendButton: View {
    let enabled: Bool
    let action: () -> Void
    @ViewState private var hovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        Button(action: action) {
            HStack(spacing: 9) {
                Text(L("Send"))
                Image(systemName: "arrow.up").font(.system(size: 13, weight: .medium))
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(enabled ? ChatColors.sendText : PrismTheme.textMuted)
            .padding(.horizontal, 12)
            .frame(minHeight: 34)
            .background {
                if enabled {
                    shape.fill(LinearGradient(colors: [ChatColors.sendTop, ChatColors.sendBottom], startPoint: .topLeading, endPoint: .bottomTrailing))
                } else {
                    shape.fill(PrismTheme.surfaceSelected)
                }
            }
            .overlay(shape.strokeBorder(enabled ? ChatColors.sendBorder : PrismTheme.line))
            .opacity(enabled ? 1 : 0.8)
            .shadow(color: .black.opacity(enabled && hovered ? 0.25 : 0), radius: 6, y: 3)
            .offset(y: enabled && hovered && !ChatMotion.reduce ? -1 : 0)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.14), value: hovered)
    }
}

/// `.ai-tool-chip`: a quiet toggle that lights up while local files are on.
private struct FilesChip: View {
    let on: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 4) {
                Image(systemName: "folder").font(.system(size: 12))
                Text(L("Files")).font(.system(size: 10))
            }
            .foregroundStyle(on ? PrismTheme.accent : PrismTheme.textMuted)
            .padding(7)
        }
        .buttonStyle(ChatButtonStyle(fill: on ? PrismTheme.accent.opacity(0.09) : .clear,
                                     stroke: on ? PrismTheme.accent.opacity(0.3) : .clear, radius: 7))
        .accessibilityLabel(L("Use local files for this question"))
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// `.ai-rename`: an inline field under the header.
private struct RenameRow: View {
    @ViewState private var title: String
    let saving: Bool
    let cancel: () -> Void
    let save: (String) async -> Void
    @FocusState private var focused: Bool
    @ViewState private var pending = false

    init(title: String, saving: Bool, cancel: @escaping () -> Void, save: @escaping (String) async -> Void) {
        _title = ViewState(initialValue: title)
        self.saving = saving
        self.cancel = cancel
        self.save = save
    }

    var body: some View {
        HStack(spacing: 7) {
            TextField(text: $title, prompt: Text(L("Conversation name")).foregroundStyle(PrismTheme.textMuted)) { Text(L("Conversation name")) }
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(PrismTheme.text)
                .focused($focused)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(PrismTheme.surface))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(PrismTheme.lineStrong))
                .onSubmit(commit)
                .onChange(of: title) { _, value in if value.count > 70 { title = String(value.prefix(70)) } }
            SmallButton(title: L("Save"), action: commit)
                .disabled(saving || pending || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            SmallButton(title: L("Cancel"), action: cancel)
                .disabled(saving || pending)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .onAppear { focused = true }
    }

    private func commit() {
        guard !pending, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        pending = true
        Task {
            await save(title)
            pending = false
        }
    }
}

/// The small bordered buttons of notices and errors (`.ai-notice button`).
private struct SmallButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(verbatim: title)
                .font(.system(size: 11))
                .foregroundStyle(PrismTheme.text)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
        }
        .buttonStyle(ChatButtonStyle(fill: PrismTheme.surface, stroke: PrismTheme.lineStrong, radius: 5))
    }
}

/// `.ai-delete-dialog` over a dimmed thread.
private struct DeleteDialog: View {
    @Bindable var model: ChatModel
    let target: ChatSession

    var body: some View {
        ZStack {
            Rectangle()
                .fill(ChatColors.shell.opacity(0.7))
                .contentShape(Rectangle())
                .onTapGesture {}
            VStack(alignment: .leading, spacing: 0) {
                Text(L("Delete this conversation?"))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(PrismTheme.text)
                    .padding(.bottom, 10)
                Text(L("Delete all messages and drafts in “\(target.displayTitle)”?"))
                    .font(.system(size: 13))
                    .foregroundStyle(PrismTheme.textMuted)
                    .chatLineHeight(13, 1.6)
                    .fixedSize(horizontal: false, vertical: true)
                if let error = model.deleteError {
                    Text(verbatim: error)
                        .font(.system(size: 12))
                        .foregroundStyle(PrismTheme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 10)
                }
                HStack(spacing: 8) {
                    Spacer()
                    Button(L("Cancel")) { model.deleteTarget = nil }
                        .buttonStyle(.prism)
                        .keyboardShortcut(.cancelAction)
                        .disabled(model.switching)
                    Button(model.switching ? L("Deleting…") : model.deleteError == nil ? L("Delete") : L("Retry delete")) {
                        Task { await model.performDelete() }
                    }
                    .buttonStyle(.prismDestructive)
                    .disabled(model.switching)
                }
                .padding(.top, 20)
            }
            .padding(22)
            .frame(width: 360)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(ChatColors.shell))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(PrismTheme.lineStrong))
            .shadow(color: .black.opacity(0.2), radius: 30, y: 16)
            .padding(24)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }
}

// MARK: Pieces

/// The visible messages, the pending question, the streaming answer and status lines.
struct TranscriptRows: View {
    let model: ChatModel
    let display: [ChatTurn]
    let offset: Int
    var onShowEarlier: () -> Void = {}

    private var request: ChatRequestState { model.activeRequest }

    var body: some View {
        if offset > 0 {
            // `.ai-load-earlier`
            Button {
                onShowEarlier()
                model.visibleMessageCount += 60
            } label: {
                Text(L("Show earlier messages"))
                    .font(.system(size: 12))
                    .foregroundStyle(PrismTheme.text)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
            .buttonStyle(ChatButtonStyle(stroke: PrismTheme.lineStrong, radius: 7))
            .frame(maxWidth: .infinity)
            .padding(.bottom, 20)
        }
        if display.isEmpty {
            WelcomeView(model: model)
        } else {
            ForEach(offset..<display.count, id: \.self) { index in
                MessageRow(model: model, message: display[index], index: index,
                           isSaved: index < model.current.messages.count, streaming: index >= model.current.messages.count && display[index].role == "assistant")
                    .id(index)
            }
        }
        Group {
            if !request.streamed.isEmpty && !request.isRunning {
                Text(L("Interrupted answer · Send the question below again to continue."))
                    .font(.system(size: 11))
                    .foregroundStyle(PrismTheme.textMuted)
            }
            if request.isRunning && request.streamed.isEmpty {
                // `.ai-thinking`
                HStack(spacing: 8) {
                    PulsingDot()
                    Text(request.compacting ? L("Summarizing earlier conversation…") : request.pending.isEmpty ? L("Saving your question…") : L("Writing a reply…"))
                        .font(.system(size: 13))
                        .foregroundStyle(PrismTheme.textMuted)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: ChatMetrics.messageWidth, alignment: .leading)
        .frame(maxWidth: .infinity)
    }
}

private struct PulsingDot: View {
    @ViewState private var dim = false

    var body: some View {
        Circle()
            .fill(PrismTheme.accent)
            .frame(width: 6, height: 6)
            .opacity(dim ? 0.3 : 1)
            .onAppear {
                guard !ChatMotion.reduce else { return }
                withAnimation(.easeInOut(duration: 0.65).repeatForever(autoreverses: true)) { dim = true }
            }
    }
}

/// `.ai-welcome`: the sparkles tile, headline, hint and either presets or the settings button.
private struct WelcomeView: View {
    let model: ChatModel

    private var presets: [(String, String)] {
        [
            (L("Summarize"), L("Summarize the following concisely, keeping only the key points:\n\n")),
            (L("Translate to Korean"), L("Translate the following into natural Korean:\n\n")),
            (L("Translate to English"), L("Translate the following into natural English:\n\n")),
            (L("Polish writing"), L("Polish the following text to read naturally and clearly while keeping its meaning:\n\n")),
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "sparkles")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(PrismTheme.accent)
                .frame(width: 54, height: 54)
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(PrismTheme.lineStrong))
                .padding(.bottom, 20)
            Text(L("What would you like to work on?"))
                .font(.system(size: 23, weight: .semibold))
                .tracking(-0.69)
                .foregroundStyle(PrismTheme.text)
                .padding(.bottom, 10)
            Text(model.readyToSend ? L("Ask a question or paste some text.") : model.checking ? L("Checking your saved AI connection…") : L("Connect an API key and choose a model to start chatting."))
                .font(.system(size: 13))
                .foregroundStyle(PrismTheme.textMuted)
                .multilineTextAlignment(.center)
                .chatLineHeight(13, 1.6)
                .padding(.bottom, 14)
            if model.readyToSend {
                HStack(spacing: 7) {
                    ForEach(presets, id: \.0) { preset in
                        Button { model.applyPreset(preset.1) } label: {
                            Text(verbatim: preset.0)
                                .font(.system(size: 12))
                                .foregroundStyle(PrismTheme.text)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                        }
                        .buttonStyle(ChatButtonStyle(fill: PrismTheme.surface, stroke: PrismTheme.lineStrong, radius: 7))
                    }
                }
                .padding(.top, 4)
                .padding(.bottom, 16)
            } else if !model.checking {
                Button { model.openSettings() } label: {
                    Text(L("Open AI settings"))
                        .font(.system(size: 16))
                        .foregroundStyle(PrismTheme.text)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                }
                .buttonStyle(ChatButtonStyle(fill: PrismTheme.surface, stroke: PrismTheme.lineStrong, radius: 7))
            }
        }
        .frame(maxWidth: .infinity, minHeight: 165)
    }
}

/// `.ai-message`: a label row with hover actions, then a user bubble or the Markdown answer.
private struct MessageRow: View {
    let model: ChatModel
    let message: ChatTurn
    let index: Int
    let isSaved: Bool
    let streaming: Bool
    @ViewState private var hovering = false

    private var isUser: Bool { message.role == "user" }

    var body: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(verbatim: isUser ? L("You") : (message.modelName ?? model.current.modelLabel))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(PrismTheme.textMuted)
                    .lineLimit(1)
                actions
            }
            .frame(minHeight: 28)
            .padding(.bottom, 6)
            if let image = message.image {
                ImageThumbnail(image: image, maxWidth: 420, maxHeight: 220)
                    .padding(.vertical, 8)
            }
            if isUser {
                Text(verbatim: message.content)
                    .font(.system(size: 14))
                    .foregroundStyle(PrismTheme.text)
                    .chatLineHeight(14, 1.8)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(PrismTheme.surfaceSelected))
                    .frame(maxWidth: ChatMetrics.messageWidth * 0.9, alignment: .trailing)
            } else {
                MarkdownView(text: message.content) { model.copy($0, notice: L("Copied code")) }
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: ChatMetrics.messageWidth, alignment: isUser ? .trailing : .leading)
        .frame(maxWidth: .infinity)
        .padding(.bottom, 28)
        .onHover { hovering = $0 }
        .transition(.opacity.combined(with: .offset(y: 7)))
    }

    private var actions: some View {
        HStack(spacing: 0) {
            ChatIconButton(systemImage: "doc.on.doc", size: 11, label: isUser ? L("Copy question") : L("Copy answer"), tint: PrismTheme.textMuted) {
                model.copy(message.content)
            }
            if isSaved {
                ChatIconButton(systemImage: isUser ? "pencil" : "arrow.counterclockwise", size: 11,
                               label: isUser ? L("Edit the question and continue in a new conversation") : L("Keep the original and regenerate"),
                               tint: PrismTheme.textMuted) {
                    model.fork(at: isUser ? index : index - 1, regenerate: !isUser)
                }
                .disabled(model.busy || model.switching)
                .accessibilityLabel(isUser ? L("Edit question") : L("Regenerate answer"))
            }
        }
        .frame(height: 22)
        .opacity(hovering && !streaming ? 1 : 0)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

private struct ImageThumbnail: View {
    let image: ChatImage
    var maxWidth: CGFloat = 320
    var maxHeight: CGFloat = 160
    @ViewState private var nsImage: NSImage?

    var body: some View {
        Group {
            if let nsImage {
                Image(nsImage: nsImage).resizable().aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: 8).fill(PrismTheme.surfaceStrong).frame(width: 120, height: 80)
            }
        }
        .frame(maxWidth: maxWidth, maxHeight: maxHeight)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(PrismTheme.lineStrong))
        .accessibilityLabel(L("Image attachment"))
        .task(id: image.dataUrl.count) { nsImage = ChatImageCache.shared.image(for: image) }
    }
}

/// Decoded attachments, bounded so long conversations with screenshots stay light.
@MainActor
final class ChatImageCache {
    static let shared = ChatImageCache()
    private let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 24
        return cache
    }()

    func image(for image: ChatImage) -> NSImage? {
        let key = String(image.dataUrl.suffix(96)) + "\(image.dataUrl.utf8.count)"
        if let cached = cache.object(forKey: key as NSString) { return cached }
        guard let data = Data(base64Encoded: String(image.dataUrl.dropFirst(ChatImageCodec.prefix.count))), let decoded = NSImage(data: data) else { return nil }
        cache.setObject(decoded, forKey: key as NSString)
        return decoded
    }
}

/// `.ai-capture-attachment`
private struct AttachmentPreview: View {
    let image: ChatImage
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ImageThumbnail(image: image, maxWidth: 100, maxHeight: 64)
                .frame(width: 100, height: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(L("Image attachment")).font(.system(size: 12)).foregroundStyle(PrismTheme.text)
                Text(L("Sent with your question · Choose a model that supports images")).font(.system(size: 11)).foregroundStyle(PrismTheme.textMuted)
            }
            Spacer(minLength: 0)
            ChatIconButton(systemImage: "xmark", size: 12, label: L("Remove image"), tint: PrismTheme.textSecondary, action: remove)
        }
    }
}

/// `.ai-request-error`: the first line, optional details and recovery buttons, outlined in the danger color.
private struct ErrorBanner: View {
    let message: String
    let canRetry: Bool
    let retry: () -> Void
    let settings: () -> Void

    var body: some View {
        let lines = message.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: lines[0])
                .font(.system(size: 12))
                .foregroundStyle(PrismTheme.danger)
                .fixedSize(horizontal: false, vertical: true)
            if lines.count > 1 {
                PrismDisclosure(Text(L("Error details"))) {
                    ScrollView {
                        Text(verbatim: lines[1])
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(PrismTheme.textSecondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 80)
                }
                .font(.system(size: 11))
            }
            HStack(spacing: 6) {
                SmallButton(title: L("Send again"), action: retry).disabled(!canRetry)
                SmallButton(title: L("Model & connection settings"), action: settings)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(PrismTheme.danger))
    }
}

/// `.ai-notice`: a muted line with an optional small action.
private struct NoticeRow: View {
    let text: String
    var action: String?
    var isError = false
    var perform: () -> Void = {}

    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: text)
                .foregroundStyle(isError ? PrismTheme.danger : PrismTheme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            if let action { SmallButton(title: action, action: perform) }
            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 24)
        .padding(.bottom, 10)
    }
}
