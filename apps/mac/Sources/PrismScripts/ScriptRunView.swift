import AppKit
import PrismKit
import SwiftUI

/// The run screen: typed argument fields, status, and live output. Going back never cancels; the run keeps
/// going and the screen reattaches when the command is opened again.
struct ScriptRunView: View {
    let model: ScriptsModel
    let actions: ScriptActions
    let scriptID: String

    @FocusState private var focus: Field?

    private enum Field: Hashable { case argument(Int), output }

    private var command: ScriptCommandSummary? { model.command(scriptID) }
    private var session: ScriptSession { model.session(scriptID) }
    private var snapshot: ScriptRunSnapshot? { session.snapshot }
    private var arguments: [ScriptArgument] { command?.arguments ?? [] }
    private var isBusy: Bool { session.isRunning }

    private var isInvalid: Bool {
        guard let command else { return true }
        if command.argumentError != nil { return true }
        return arguments.indices.contains { index in !arguments[index].optional && value(index).isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if !arguments.isEmpty && command?.argumentError == nil {
                argumentBar
            }
            notices
            output
            footer
        }
        .onAppear {
            Task { @MainActor in
                // Let the screen join the window before taking focus from the root search field.
                try? await Task.sleep(for: .milliseconds(30))
                focus = arguments.isEmpty ? .output : .argument(0)
            }
        }
    }

    // MARK: Header

    /// `.script-run-header`: back arrow, title and description, and the run state on the right.
    private var header: some View {
        HStack(spacing: 12) {
            PrismBackButton(help: Text("Back", bundle: .module)) { actions.context.popScreen() }
            if let command {
                PaletteIconImage(icon: actions.icon(for: command))
                    .frame(width: 26, height: 26)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: command?.title ?? ScriptStrings.localized("Script command"))
                    .font(.prism(16, weight: 550))
                    .foregroundStyle(PrismTheme.text)
                    .lineLimit(1)
                if let subtitle = command?.description ?? command?.packageName {
                    Text(verbatim: subtitle)
                        .font(.prism(12))
                        .foregroundStyle(PrismTheme.textMuted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 16)
            ScriptStatusBadge(session: session, configuredTimeout: command?.timeoutSeconds)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .frame(minHeight: 66)
        .overlay(alignment: .bottom) { PrismRule(strong: true) }
    }

    private var argumentBar: some View {
        HStack(spacing: 8) {
            ForEach(Array(arguments.enumerated()), id: \.offset) { index, argument in
                argumentField(argument, index: index)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 26)
        .padding(.top, 18)
        .disabled(isBusy)
    }

    @ViewBuilder
    private func argumentField(_ argument: ScriptArgument, index: Int) -> some View {
        let binding = Binding(get: { value(index) }, set: { setValue($0, at: index) })
        let prompt = argument.optional ? "\(argument.placeholder) (\(ScriptStrings.localized("Optional")))" : argument.placeholder
        Group {
            switch argument.kind {
            case .dropdown:
                let selected = argument.data.first { $0.value == binding.wrappedValue }
                Menu {
                    if argument.optional {
                        Button { binding.wrappedValue = "" } label: { Text("None", bundle: .module) }
                        Divider()
                    }
                    ForEach(Array(argument.data.enumerated()), id: \.offset) { _, option in
                        Button { binding.wrappedValue = option.value } label: {
                            if option.value == binding.wrappedValue {
                                Label { Text(verbatim: option.title) } icon: { Image(systemName: "checkmark") }
                            } else {
                                Text(verbatim: option.title)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(verbatim: selected?.title ?? prompt)
                            .foregroundStyle(selected == nil ? PrismTheme.textMuted : PrismTheme.text)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(PrismTheme.textMuted)
                    }
                    .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .focused($focus, equals: .argument(index))
                .padding(.horizontal, 10)
                .frame(height: 35)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.black.opacity(0.03)))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(PrismTheme.lineStrong))
            case .password:
                SecureField(text: binding, prompt: Text(verbatim: prompt)) { Text(verbatim: argument.placeholder) }
                    .textFieldStyle(.plain)
                    .focused($focus, equals: .argument(index))
                    .onSubmit { submitFromField(index) }
                    .padding(.horizontal, 10)
                    .frame(height: 35)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.black.opacity(0.03)))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(PrismTheme.lineStrong))
            case .text:
                TextField(text: binding, prompt: Text(verbatim: prompt)) { Text(verbatim: argument.placeholder) }
                    .textFieldStyle(.plain)
                    .focused($focus, equals: .argument(index))
                    .onSubmit { submitFromField(index) }
                    .padding(.horizontal, 10)
                    .frame(height: 35)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.black.opacity(0.03)))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(PrismTheme.lineStrong))
            }
        }
        .font(.prism(12))
        .foregroundStyle(PrismTheme.text)
        .frame(maxWidth: 240)
        .accessibilityLabel(Text(verbatim: argument.placeholder))
    }

    // MARK: Notices

    @ViewBuilder
    private var notices: some View {
        let items = noticeItems
        if !items.isEmpty {
            // `.script-run-status`: a quiet bordered card above the output.
            VStack(alignment: .leading, spacing: 8) {
                ForEach(items) { notice in
                    ScriptNoticeRow(notice: notice)
                }
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(PrismTheme.surface))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(PrismTheme.line))
            .padding(.horizontal, 26)
            .padding(.top, 18)
        }
    }

    private var noticeItems: [ScriptNotice] {
        var items: [ScriptNotice] = []
        if let error = model.historyError {
            items.append(ScriptNotice(id: "history", kind: .error, text: ScriptStrings.localize(error)))
        }
        guard let command else {
            items.append(ScriptNotice(id: "missing", kind: .error, text: ScriptStrings.localize("The script command is not present in the current registry.")))
            return items
        }
        if let error = command.argumentError {
            items.append(ScriptNotice(id: "metadata", kind: .warning, text: ScriptStrings.localized("Invalid script metadata. Fix the script and refresh commands."),
                                      detail: ScriptStrings.localize(error)))
        }
        if command.needsConfirmation && snapshot == nil && !isBusy {
            items.append(ScriptNotice(id: "confirm", kind: .info, text: ScriptStrings.localized("This script asks for confirmation before it runs. Press Return to run it.")))
        }
        if snapshot?.state == .interrupted {
            items.append(ScriptNotice(id: "interrupted", kind: .warning, text: ScriptStrings.localized("This run was interrupted by a Prism restart. Review any side effects before running again.")))
        } else if let error = snapshot?.error {
            items.append(ScriptNotice(id: "run-error", kind: .error, text: ScriptStrings.localize(error)))
        }
        if snapshot?.state == .timedOut, let seconds = snapshot?.timeoutSeconds {
            items.append(ScriptNotice(id: "timeout", kind: .warning, text: ScriptStrings.localized("Script timed out after \(Int(seconds)) seconds")))
        }
        if let error = session.error {
            let retry: ScriptNotice.Action? = session.errorOperation == .cancel && snapshot?.state == .running
                ? .init(title: ScriptStrings.localized("Retry cancel")) { Task { await model.cancel(scriptID) } } : nil
            items.append(ScriptNotice(id: "session-error", kind: .error, text: ScriptStrings.localize(error), action: retry))
        }
        if snapshot?.persistenceError != nil || session.errorOperation == .save {
            items.append(ScriptNotice(
                id: "persistence", kind: .error, text: ScriptStrings.localized("Run history could not be saved. Execution will not be repeated."),
                detail: snapshot?.persistenceError.map(ScriptStrings.localize),
                action: .init(title: ScriptStrings.localized("Retry saving history")) { Task { await model.retryPersistence(scriptID) } }
            ))
        }
        if snapshot?.outputWithheld == true {
            items.append(ScriptNotice(id: "withheld", kind: .info, text: ScriptStrings.localized("Output was not saved because this script accepts a password argument.")))
        }
        return items
    }

    // MARK: Output

    @ViewBuilder
    private var output: some View {
        Group {
            if let snapshot {
                ScriptOutputView(stdout: snapshot.stdout, stderr: snapshot.stderr, follows: snapshot.state == .running)
                    .overlay {
                        if snapshot.stdout.isEmpty && snapshot.stderr.isEmpty {
                            Text("No output yet.", bundle: .module)
                                .font(.prism(11))
                                .foregroundStyle(PrismTheme.textMuted)
                                .allowsHitTesting(false)
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if snapshot.stdoutTruncated || snapshot.stderrTruncated {
                            Text("Output truncated at 64 KiB.", bundle: .module)
                                .font(.prism(11))
                                .foregroundStyle(PrismTheme.textMuted)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(PrismTheme.panel, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .padding(10)
                        }
                    }
                    // `.script-run-output pre`: an inset, bordered well.
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.black.opacity(0.03)))
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(PrismTheme.line))
                    .padding(.horizontal, 26)
                    .padding(.vertical, 18)
            } else if session.starting {
                Text("Starting script…", bundle: .module)
                    .font(.prism(12))
                    .foregroundStyle(PrismTheme.textMuted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .focusable()
        .focusEffectDisabled()
        .focused($focus, equals: .output)
        .onKeyPress(.return) {
            submit()
            return .handled
        }
    }

    private var emptyState: some View {
        PrismEmptyState(
            symbol: "terminal",
            title: Text("Ready to run", bundle: .module),
            message: command?.argumentError == nil
                ? Text(arguments.isEmpty ? "Press Return to run this script." : "Fill in the arguments, then press Return.", bundle: .module)
                : nil
        )
    }

    // MARK: Footer

    private var footer: some View {
        PrismStatusBar {
            Group {
                if isBusy {
                    Text("You can go back while the script runs.", bundle: .module)
                } else if let command {
                    Text("Timeout: \(command.timeoutSeconds) seconds", bundle: .module)
                }
            }
            .lineLimit(1)
            .padding(.horizontal, 7)
        } trailing: {
            if snapshot?.state == .running {
                PrismStatusAction(session.cancelling ? Text("Cancelling…", bundle: .module) : Text("Cancel", bundle: .module), keys: "⌘.") {
                    Task { await model.cancel(scriptID) }
                }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(session.cancelling)
                PrismStatusDivider()
            }
            if let snapshot, !(snapshot.stdout.isEmpty && snapshot.stderr.isEmpty) {
                PrismStatusAction(Text("Copy Output", bundle: .module), keys: "⇧⌘C", action: copyOutput)
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                PrismStatusDivider()
            }
            PrismStatusAction(runTitle, keys: "↵", isPrimary: true, action: submit)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(isBusy || isInvalid || model.historyError != nil)
            PrismStatusDivider()
            PrismStatusAction(Text("Back", bundle: .module), keys: "esc") { actions.context.popScreen() }
        }
    }

    private var runTitle: Text {
        if session.errorOperation == .start { return Text("Retry start", bundle: .module) }
        return snapshot == nil ? Text("Run Script", bundle: .module) : Text("Run Again", bundle: .module)
    }

    // MARK: Behavior

    private func value(_ index: Int) -> String { model.draft(scriptID, index) }

    private func setValue(_ value: String, at index: Int) {
        model.setDraft(String(value.prefix(ScriptLimits.maxArgumentBytes)), scriptID, index, count: arguments.count)
    }

    /// Return in a field runs when every required value is present; otherwise it moves to the first missing one.
    private func submitFromField(_ index: Int) {
        guard !Self.isComposingText() else { return }
        if let missing = arguments.indices.first(where: { !arguments[$0].optional && value($0).isEmpty }), command?.argumentError == nil {
            focus = .argument(missing)
            return
        }
        submit()
    }

    private func submit() {
        guard !Self.isComposingText(), let command, !isBusy, !isInvalid, model.historyError == nil else { return }
        let submitted = arguments.indices.map(value)
        // Never keep password values for retry or restoration.
        for index in arguments.indices where arguments[index].kind == .password { setValue("", at: index) }
        if command.mode == .silent {
            actions.runSilently(scriptID, arguments: submitted)
            actions.context.hidePalette()
            return
        }
        if command.mode == .inline { model.enableInlineRefresh(scriptID) }
        Task { await model.start(scriptID, arguments: submitted, rerun: true) }
        focus = .output
    }

    private func copyOutput() {
        guard let snapshot else { return }
        let text = [ScriptOutput.plain(snapshot.stdout), ScriptOutput.plain(snapshot.stderr)].filter { !$0.isEmpty }.joined(separator: "\n")
        PasteService.copy(text)
        actions.context.showHUD(ScriptStrings.localized("Copied to Clipboard"))
    }

    /// Return while an input method is composing (Korean, Japanese) commits the text; it must not run the script.
    static func isComposingText() -> Bool {
        (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() ?? false
    }
}

struct ScriptNotice: Identifiable {
    enum Kind { case info, warning, error }
    struct Action {
        var title: String
        var perform: @MainActor () -> Void
    }

    var id: String
    var kind: Kind
    var text: String
    var detail: String?
    var action: Action?
}

private struct ScriptNoticeRow: View {
    let notice: ScriptNotice

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .font(.system(size: 12, weight: .semibold))
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: notice.text)
                    .font(.prism(12))
                    .foregroundStyle(notice.kind == .error ? PrismTheme.danger : PrismTheme.text)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = notice.detail {
                    Text(verbatim: detail)
                        .font(.prism(11))
                        .foregroundStyle(PrismTheme.textMuted)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)
            if let action = notice.action {
                Button(action.title) { action.perform() }
                    .buttonStyle(.prism)
            }
        }
    }

    private var symbol: String {
        switch notice.kind {
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    private var tint: Color {
        switch notice.kind {
        case .info: PrismTheme.textMuted
        case .warning: PrismTheme.warning
        case .error: PrismTheme.danger
        }
    }
}

struct ScriptStatusBadge: View {
    let session: ScriptSession
    let configuredTimeout: Int?

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 6) {
                    indicator
                    title
                        .font(.prism(12, weight: 550))
                        .foregroundStyle(tint)
                }
                if let result = session.snapshot?.result {
                    Group {
                        if let code = result.exitCode {
                            Text("\(Int(result.durationMs)) ms · Exit code \(Int(code))", bundle: .module)
                        } else {
                            Text("\(Int(result.durationMs)) ms", bundle: .module)
                        }
                    }
                    .font(.prism(11).monospacedDigit())
                    .foregroundStyle(PrismTheme.textMuted)
                }
            }
        }
    }

    @ViewBuilder
    private var indicator: some View {
        if session.isRunning {
            ProgressView().controlSize(.mini)
        } else if let symbol {
            Image(systemName: symbol).foregroundStyle(tint).font(.system(size: 12, weight: .semibold))
        }
    }

    private var state: ScriptRunState? { session.snapshot?.state }

    private var title: Text {
        if session.starting { return Text("Starting script…", bundle: .module) }
        if session.cancelling { return Text("Cancelling…", bundle: .module) }
        switch state {
        case .running: return Text("Running", bundle: .module)
        case .success: return Text("Script succeeded", bundle: .module)
        case .failure: return Text("Script failed", bundle: .module)
        case .cancelled: return Text("Script cancelled", bundle: .module)
        case .timedOut: return Text("Script timed out", bundle: .module)
        case .interrupted: return Text("Script interrupted", bundle: .module)
        case nil: return Text("Ready to run", bundle: .module)
        }
    }

    private var symbol: String? {
        switch state {
        case .success: "checkmark.circle.fill"
        case .failure: "xmark.circle.fill"
        case .cancelled: "stop.circle.fill"
        case .timedOut: "clock.badge.exclamationmark.fill"
        case .interrupted: "exclamationmark.triangle.fill"
        case .running, nil: nil
        }
    }

    private var tint: Color {
        if session.isRunning { return PrismTheme.textSecondary }
        switch state {
        case .success: return PrismTheme.success
        case .failure: return PrismTheme.danger
        case .timedOut, .interrupted: return PrismTheme.warning
        case .cancelled, .running, nil: return PrismTheme.textMuted
        }
    }
}

/// Draws a palette icon outside the shell's row view.
struct PaletteIconImage: View {
    let icon: PaletteIcon

    var body: some View {
        switch icon {
        case .symbol(let name, _):
            Image(systemName: PrismGlyph.outline(name)).font(.system(size: 16, weight: .light)).foregroundStyle(PrismTheme.textSecondary)
        case .file(let path):
            Image(nsImage: AppIconCache.shared.icon(forPath: path)).resizable()
        case .image(let image):
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
        case .text(let text):
            Text(verbatim: text).font(.system(size: 20))
        case .none:
            Color.clear
        }
    }
}

/// Read-only, selectable output with ANSI colors. Keeps following the end while the run is live and the user has
/// not scrolled up.
struct ScriptOutputView: NSViewRepresentable {
    let stdout: String
    let stderr: String
    let follows: Bool

    final class Coordinator {
        var stdout = ""
        var stderr = ""
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        let textView = scrollView.documentView as! NSTextView
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isRichText = true
        textView.textContainerInset = NSSize(width: 14, height: 12)
        textView.textContainer?.lineFragmentPadding = 0
        textView.isAutomaticLinkDetectionEnabled = false
        textView.setAccessibilityLabel(ScriptStrings.localized("Standard output"))
        apply(to: textView, coordinator: context.coordinator, scrollView: scrollView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        apply(to: textView, coordinator: context.coordinator, scrollView: scrollView)
    }

    private func apply(to textView: NSTextView, coordinator: Coordinator, scrollView: NSScrollView) {
        guard coordinator.stdout != stdout || coordinator.stderr != stderr || textView.textStorage?.length == 0 else { return }
        let atEnd = scrollView.contentView.bounds.maxY >= (scrollView.documentView?.frame.height ?? 0) - 24
        coordinator.stdout = stdout
        coordinator.stderr = stderr
        let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        let text = NSMutableAttributedString(attributedString: ScriptOutput.attributed(stdout, font: font))
        if !stderr.isEmpty {
            if text.length > 0 && !stdout.hasSuffix("\n") { text.append(NSAttributedString(string: "\n")) }
            if text.length > 0 { text.append(NSAttributedString(string: "\n")) }
            text.append(NSAttributedString(string: ScriptStrings.localized("Standard error") + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor,
            ]))
            text.append(ScriptOutput.attributed(stderr, font: font, baseColor: .systemRed))
        }
        textView.textStorage?.setAttributedString(text)
        if follows && atEnd { textView.scrollToEndOfDocument(nil) }
    }
}
