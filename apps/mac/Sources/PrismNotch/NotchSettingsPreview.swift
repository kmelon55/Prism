import AppKit
import PrismKit
import SwiftUI

/// The live notch beside Notch settings. It renders the real `NotchView` against the shared model, so pinned
/// tools, their order and a running timer look exactly as they will at the top of the screen. The preview has
/// its own presentation; opening it here never opens the panel on screen.
struct NotchSettingsPreview: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var model: NotchModel
    let display: NotchDisplay?
    @ViewState private var session = NotchDisplaySession()

    private var mode: NotchPresentation.Mode { session.presentation.mode }
    private var geometry: NotchGeometry {
        display?.geometry(active: model.hasActivity) ?? NotchGeometry(
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982), cameraWidth: 180, topInset: 34, showsActivity: model.hasActivity)
    }
    /// Every mode fits without scaling at this size; narrower columns scale the whole stage down.
    private var stageSize: CGSize {
        CGSize(width: geometry.expandedWidth + 40, height: geometry.headerHeight + 296 + 84)
    }

    var body: some View {
        VStack(spacing: 14) {
            Color.clear
                .aspectRatio(stageSize.width / stageSize.height, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .topLeading) {
                    GeometryReader { proxy in
                        let scale = min(1, proxy.size.width / stageSize.width)
                        stage
                            .frame(width: proxy.size.width / scale, height: proxy.size.height / scale)
                            .scaleEffect(scale, anchor: .topLeading)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(PrismTheme.lineStrong))
            modePicker
            caption
        }
        .onChange(of: model.preferences.hoverPreview) { _, enabled in
            if !enabled, mode == .preview { show(.compact) }
        }
    }

    private var stage: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.22, green: 0.23, blue: 0.26), Color(red: 0.09, green: 0.09, blue: 0.11)],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [.white.opacity(0.10), .clear], center: UnitPoint(x: 0.25, y: 0.9), startRadius: 0, endRadius: 320)
            menuBar
            notch
            if !model.preferences.enabled { disabledBadge }
        }
        .environment(\.colorScheme, .dark)
    }

    private var menuBar: some View {
        HStack(spacing: 14) {
            Image(systemName: "apple.logo").font(.system(size: 12))
            ForEach([34, 26, 28, 30], id: \.self) { width in
                Capsule().frame(width: CGFloat(width), height: 5)
            }
            Spacer()
            ForEach([18, 22], id: \.self) { width in
                Capsule().frame(width: CGFloat(width), height: 5)
            }
            Image(systemName: "wifi").font(.system(size: 11))
            Text(verbatim: "9:41").font(.system(size: 11, weight: .medium)).monospacedDigit()
        }
        .foregroundStyle(.white.opacity(0.42))
        .padding(.horizontal, 14)
        .frame(height: geometry.cameraWidth > 0 ? geometry.topInset : 24)
        .frame(maxWidth: .infinity)
        .background(.white.opacity(0.05))
    }

    private var notch: some View {
        let frame = geometry.frame(mode: mode)
        return NotchView(model: model, session: session, geometry: geometry, mode: mode, motionDisabled: reduceMotion,
                         toggle: { show(mode == .expanded ? .compact : .expanded) },
                         open: { show(.expanded) },
                         close: { show(.compact) })
            .frame(width: frame.width, height: frame.height)
            .id(mode)
            .transition(.opacity)
            .frame(width: frame.width, height: frame.height, alignment: .top)
            .background(.black)
            .clipShape(NotchOutline())
            .opacity(model.preferences.enabled ? 1 : 0.55)
    }

    private var disabledBadge: some View {
        VStack {
            Spacer()
            HStack(spacing: 10) {
                Image(systemName: "eye.slash").font(.system(size: 11, weight: .medium))
                Text(N("The notch is off")).font(.system(size: 11.5, weight: .medium))
                Button { model.setEnabled(true) } label: {
                    Text(N("Turn On")).font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(.white.opacity(0.16), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(.white.opacity(0.85))
            .padding(.leading, 14).padding(.trailing, 6).padding(.vertical, 6)
            .background(.black.opacity(0.55), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.08)))
            .padding(.bottom, 18)
        }
    }

    private var modePicker: some View {
        HStack(spacing: 2) {
            modeButton(.compact, N("Collapsed"), "minus")
            modeButton(.preview, N("Hover"), "cursorarrow", enabled: model.preferences.hoverPreview)
            modeButton(.expanded, N("Expanded"), "rectangle.expand.vertical")
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(PrismTheme.surfaceStrong))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(PrismTheme.line))
    }

    private func modeButton(_ value: NotchPresentation.Mode, _ title: String, _ symbol: String, enabled: Bool = true) -> some View {
        let active = mode == value
        return Button { show(value) } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 10.5, weight: .medium))
                Text(verbatim: title).font(.system(size: 11.5, weight: .semibold)).lineLimit(1).fixedSize()
            }
            .foregroundStyle(active ? PrismTheme.text : PrismTheme.textMuted)
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background {
                if active { RoundedRectangle(cornerRadius: 7, style: .continuous).fill(PrismTheme.selection) }
            }
            .prismHighlight(active: active)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .help(enabled ? title : N("Turn on Preview on hover to use this state."))
    }

    private var caption: some View {
        VStack(spacing: 4) {
            if let display {
                Text(verbatim: String(format: N("Shown as on %@"), display.name.isEmpty ? N("Main display") : display.name))
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(PrismTheme.textSecondary)
            }
            Text(N("Click the notch to try it. Changes on the left appear here right away."))
                .font(.system(size: 11)).foregroundStyle(PrismTheme.textMuted)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }

    private func show(_ value: NotchPresentation.Mode) {
        var next = NotchPresentation()
        switch value {
        case .compact: break
        case .preview: next.preview()
        case .expanded: next.open()
        }
        withAnimation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.82)) { session.presentation = next }
    }
}
