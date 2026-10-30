import PrismKit
import SwiftUI

/// Refine speech and Structure prompt: two independent cards, each with its own model and instructions
/// (Tauri `DictationProcessing`, `.dictation-processing-grid`).
struct EnhancementSection: View {
    let service: DictationService

    private var settings: DictationSettings { service.settings }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PrismSectionHeading(Text("Dictation enhancement", bundle: .module)) {
                if settings.mode == .off {
                    Text("Off · Original transcription", bundle: .module)
                } else {
                    Text("Enable either or both", bundle: .module)
                }
            }
            HStack(alignment: .top, spacing: 12) {
                ForEach([ProcessingMode.cleanup, .prompt], id: \.self) { mode in
                    EnhancementCard(service: service, mode: mode)
                }
            }
            if settings.mode != .off {
                DictationNote(Text("Only dictated text is sent to the selected provider. One extra AI request per processed result.", bundle: .module))
            }
        }
        .padding(.vertical, 8)
    }
}

private struct EnhancementCard: View {
    let service: DictationService
    let mode: ProcessingMode

    private var settings: DictationSettings { service.settings }
    private var enabled: Bool { settings.mode.includes(mode) }
    private var selection: ProcessingSelection? { mode == .cleanup ? settings.cleanupModel : settings.promptModel }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 9) {
                    Image(systemName: mode == .cleanup ? "sparkles" : "wand.and.stars").font(.system(size: 14))
                    Text(mode == .cleanup ? "Refine speech" : "Structure prompt", bundle: .module)
                        .font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 8)
                    Circle()
                        .fill(enabled ? PrismTheme.accent : .clear)
                        .overlay(Circle().strokeBorder(enabled ? .clear : PrismTheme.lineStrong))
                        .overlay {
                            if enabled { Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(PrismTheme.panel) }
                        }
                        .frame(width: 17, height: 17)
                }
                .foregroundStyle(PrismTheme.text)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isToggle)
            .accessibilityValue(enabled ? Text(verbatim: "1") : Text(verbatim: "0"))

            Text(mode == .cleanup ? "Automatically polish every dictation." : "Use a shortcut when you want a polished prompt.", bundle: .module)
                .font(.system(size: 11))
                .foregroundStyle(PrismTheme.textMuted)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 30, alignment: .topLeading)
                .padding(.top, 8)
                .padding(.bottom, 14)

            HStack {
                Text("Text processing model", bundle: .module)
                Spacer(minLength: 8)
                if let selection { Text(verbatim: selection.provider.title).font(.system(size: 10)).lineLimit(1) }
            }
            .font(.system(size: 11))
            .foregroundStyle(PrismTheme.textMuted)
            .padding(.bottom, 7)
            TextModelPicker(selection: selection) { value in
                var next = service.settings
                if mode == .cleanup { next.cleanupModel = value } else { next.promptModel = value }
                service.update(next)
            }
            .padding(.bottom, 16)

            Text("Processing prompt", bundle: .module)
                .font(.system(size: 11))
                .foregroundStyle(PrismTheme.textMuted)
                .padding(.bottom, 7)
            TextEditor(text: Binding(get: { settings.instruction(for: mode) }, set: { value in
                var next = service.settings
                let text = String(value.prefix(2000))
                if mode == .cleanup { next.cleanupInstruction = text } else { next.promptInstruction = text }
                service.update(next, delay: .milliseconds(400))
            }))
            .font(.system(size: 11))
            .foregroundStyle(PrismTheme.textSecondary)
            .lineSpacing(4)
            .scrollContentBackground(.hidden)
            .padding(6)
            .frame(height: 105)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(PrismTheme.lineStrong))
            Button {
                var next = service.settings
                if mode == .cleanup { next.cleanupInstruction = ProcessingPrompts.cleanup } else { next.promptInstruction = ProcessingPrompts.prompt }
                service.update(next)
            } label: {
                Text("Reset prompt", bundle: .module)
                    .font(.system(size: 10))
                    .foregroundStyle(PrismTheme.textMuted)
                    .padding(.top, 8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(settings.instruction(for: mode) == ProcessingPrompts.defaultInstruction(mode))
            .opacity(settings.instruction(for: mode) == ProcessingPrompts.defaultInstruction(mode) ? 0.6 : 1)

            if enabled, mode == .prompt {
                VStack(alignment: .leading, spacing: 6) {
                    DictationCommandRow(title: String(localized: "Prompt shortcut", bundle: .module), systemImage: "wand.and.stars",
                                        shortcut: service.promptShortcut)
                    DictationNote(Text("This shortcut structures and pastes a prompt. Your usual shortcut follows speech refinement settings.", bundle: .module))
                }
                .padding(.top, 12)
            }
            if enabled, selection == nil {
                Text("Choose a text processing model.", bundle: .module)
                    .font(.system(size: 11))
                    .foregroundStyle(PrismTheme.danger)
                    .padding(.top, 8)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(enabled ? PrismTheme.surfaceStrong : PrismTheme.surface))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(enabled ? PrismTheme.accent.opacity(0.45) : PrismTheme.line))
        .animation(.easeOut(duration: 0.16), value: enabled)
    }

    private func toggle() {
        var next = settings
        next.enhancementMode = settings.mode.toggling(mode)
        next.refineText = next.mode.includes(.cleanup)
        service.update(next)
    }
}

/// Provider and model for a text-processing request. Keys come from AI settings. The trigger shows the chosen model
/// (`.ai-model-trigger`) and opens the AI model catalog, as in the Tauri app; without the AI feature a small editor
/// takes the provider and model ID instead.
struct TextModelPicker: View {
    let selection: ProcessingSelection?
    let onChange: (ProcessingSelection?) -> Void
    @ViewState private var provider = TextProvider.vercel
    @ViewState private var model = ""
    @ViewState private var editing = false
    @ViewState private var browsing = false
    @FocusState private var focused: Bool

    var body: some View {
        Button { if SharedModelPicker.make != nil { browsing = true } else { editing = true } } label: {
            PrismTriggerLabel(selection.map { Text(verbatim: $0.modelName ?? $0.model) } ?? Text("Choose model", bundle: .module),
                              systemImage: "sparkles")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(PrismTriggerButtonStyle(fill: false))
        .accessibilityLabel(Text("Text processing model", bundle: .module))
        .popover(isPresented: $editing, arrowEdge: .bottom) { editor }
        .sheet(isPresented: $browsing) {
            if let make = SharedModelPicker.make {
                make(String(localized: "Text processing model", bundle: .module),
                     selection.map { .init(provider: $0.provider.rawValue, model: $0.model, modelName: $0.modelName) },
                     { choice in
                         guard let provider = TextProvider(rawValue: choice.provider) else { return }
                         let next = ProcessingSelection(provider: provider, model: choice.model, modelName: choice.modelName)
                         guard next.isValid else { return }
                         onChange(next)
                     },
                     { browsing = false })
            }
        }
        .onAppear(perform: load)
        .onChange(of: selection) { _, _ in if !focused { load() } }
        .onChange(of: editing) { _, isEditing in
            if isEditing { load() } else { commit() }
        }
    }

    private var editor: some View {
        PrismPickerPanel {
            Text("Text processing model", bundle: .module).font(.system(size: 13, weight: .semibold))
            PrismPillTabs(selection: Binding(get: { provider }, set: { provider = $0; commit() }),
                          options: TextProvider.allCases.map { ($0, $0 == .vercel ? "Vercel" : $0.title) }, expands: true)
            PrismSearchWell {
                TextField(text: $model, prompt: Text(verbatim: provider == .openai ? "gpt-5-mini" : "openai/gpt-5-mini")) {
                    Text("Model ID", bundle: .module)
                }
                .labelsHidden()
                .focused($focused)
                .onSubmit { commit(); editing = false }
            }
            HStack {
                DictationNote(Text("Keys come from AI settings.", bundle: .module))
                Button { commit(); editing = false } label: { Text("Use Model", bundle: .module) }
                    .buttonStyle(.prismPrimary)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 400)
        .onAppear { focused = true }
    }

    private func load() {
        provider = selection?.provider ?? .vercel
        model = selection?.model ?? ""
    }

    private func commit() {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = trimmed.isEmpty ? nil : ProcessingSelection(provider: provider, model: trimmed, modelName: selection?.model == trimmed ? selection?.modelName : nil)
        guard next != selection, next?.isValid ?? true else { return }
        onChange(next)
    }
}
