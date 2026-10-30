import PrismKit
import SwiftUI

/// Settings › AI › Usage: this month's cost, tokens and requests, a daily chart and a breakdown.
/// Only metadata is recorded: no prompts, answers, audio or keys. Layout follows the Tauri `AiUsage` and
/// `AiUsageChart` components (`aiUsage.css`).
struct AIUsageSection: View {
    let ledger: UsageLedger?

    @ViewState private var summary: UsageSummary?
    @ViewState private var error: String?
    @ViewState private var metric: UsagePresentation.Metric = .cost
    @ViewState private var grouping: UsagePresentation.Grouping = .feature
    @ViewState private var hovered: Int?
    @ViewState private var revision = 0

    /// The Tauri chart palette (`AiUsageChart.tsx`).
    static let palette: [Color] = [
        Color(red: 0.66, green: 0.61, blue: 0.92), Color(red: 0.51, green: 0.71, blue: 0.83), Color(red: 0.63, green: 0.79, blue: 0.71),
        Color(red: 0.85, green: 0.63, blue: 0.72), Color(red: 0.83, green: 0.73, blue: 0.56), Color(red: 0.56, green: 0.62, blue: 0.83),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading.padding(.bottom, 22)
            if let summary {
                totals(summary.month).padding(.bottom, 26)
                chart(summary)
                breakdown(summary)
                if summary.month.unknownCostRequests > 0 {
                    AINote(L("\(summary.month.unknownCostRequests) requests have no reported cost.")).padding(.bottom, 12)
                }
                PrismDisclosure(Text(L("Usage details"))) { details(summary) }
                    .padding(.vertical, 12)
            } else if let error {
                AINote(error, tone: .error)
            } else {
                AINote(L("Loading…"))
            }
        }
        .padding(.top, 24)
        .overlay(alignment: .top) { PrismHairline() }
        .task(id: revision) { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .prismAIUsageChanged)) { _ in revision += 1 }
    }

    private var heading: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 5) {
                Text(L("AI usage")).font(.system(size: 15, weight: .semibold)).foregroundStyle(PrismTheme.text)
                Text(verbatim: L("This month") + " · " + L("This device · USD"))
                    .font(.system(size: 11))
                    .foregroundStyle(PrismTheme.textMuted)
            }
            Spacer()
            Button { revision += 1 } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .medium)).frame(width: 14, height: 30)
            }
            .buttonStyle(.prism)
            .help(L("Refresh AI usage"))
            .accessibilityLabel(L("Refresh AI usage"))
        }
    }

    private func load() async {
        guard let ledger else {
            error = L("Could not read AI usage.")
            return
        }
        let since = UsageLedger.monthStart()
        do {
            summary = try await Task.detached { try ledger.summary(since: since) }.value
            error = nil
        } catch {
            self.error = L("Could not read AI usage.")
        }
    }

    // MARK: Totals

    private func totals(_ month: UsageTotals) -> some View {
        GeometryReader { proxy in
            // Columns of 1.4fr 1fr 1fr with 20 pt gaps.
            let unit = (proxy.size.width - 40) / 3.4
            HStack(alignment: .top, spacing: 20) {
                stat(L("Cost"), UsagePresentation.cost(month), unknown: false).frame(width: unit * 1.4, alignment: .leading)
                stat(L("Tokens"), month.tokens.formatted(), unknown: month.unknownTokenRequests > 0).frame(width: unit, alignment: .leading)
                stat(L("Requests"), month.requests.formatted(), unknown: false).frame(width: unit, alignment: .leading)
            }
        }
        .frame(height: 52)
    }

    private func stat(_ title: String, _ value: String, unknown: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: title).font(.system(size: 11)).foregroundStyle(PrismTheme.textMuted)
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(verbatim: value).font(.system(size: 25, weight: .medium).monospacedDigit()).tracking(-0.8)
                if unknown { Text(verbatim: " + ?").font(.system(size: 15)).foregroundStyle(PrismTheme.textMuted) }
            }
            .foregroundStyle(PrismTheme.text)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
        }
    }

    // MARK: Chart

    private func chart(_ summary: UsageSummary) -> some View {
        let days = UsagePresentation.monthDays(summary.daily)
        let elapsed = days.filter { !$0.future }
        let month = summary.month
        let allUnknown = month.requests > 0 && ((metric == .cost && month.unknownCostRequests == month.requests)
            || (metric == .tokens && month.unknownTokenRequests == month.requests))
        let values = elapsed.map { UsagePresentation.value($0.totals, metric) }
        let maximum = values.max() ?? 0
        let focused = hovered.flatMap { days.indices.contains($0) ? days[$0] : nil }
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(verbatim: focused.map { "\($0.date.formatted(date: .abbreviated, time: .omitted)) · \(UsagePresentation.label($0.totals, metric))" } ?? L("Daily usage"))
                    .font(.system(size: 11))
                    .foregroundStyle(PrismTheme.textMuted)
                Spacer()
                PrismPillTabs(selection: $metric, options: [(.cost, L("Cost")), (.tokens, L("Tokens")), (.requests, L("Requests"))])
                    .accessibilityLabel(L("Chart metric"))
            }
            UsageTimeline(count: days.count, values: values, maximum: maximum, hovered: $hovered,
                          showsLine: month.requests > 0 && !allUnknown, showsPoints: !allUnknown,
                          requests: elapsed.map(\.totals.requests),
                          maximumLabel: allUnknown ? "—" : metric == .cost ? AIPrice.format(maximum) : Int(maximum).formatted())
                .overlay {
                    if month.requests == 0 {
                        Text(L("Your usage will appear here")).font(.system(size: 12)).foregroundStyle(PrismTheme.textMuted)
                    } else if allUnknown {
                        Text(metric == .cost ? L("Cost unavailable") : L("Tokens unavailable")).font(.system(size: 12)).foregroundStyle(PrismTheme.textMuted)
                    }
                }
                .accessibilityLabel(L("Daily AI usage chart"))
                .padding(.bottom, 12)
        }
    }

    // MARK: Breakdown

    private func breakdown(_ summary: UsageSummary) -> some View {
        let groups = UsagePresentation.group(summary.breakdown, by: grouping, metric: metric)
        let largest = groups.map { UsagePresentation.value($0.totals, metric) }.max() ?? 0
        let total = UsagePresentation.value(summary.month, metric)
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                PrismPillTabs(selection: $grouping, options: [(.feature, L("Feature")), (.model, L("Model")), (.provider, L("Provider"))])
                    .accessibilityLabel(L("Group usage by"))
                Spacer()
                Text(metric == .cost ? L("Known costs") : metric == .tokens ? L("Reported tokens") : L("Requests"))
                    .font(.system(size: 10))
                    .foregroundStyle(PrismTheme.textMuted)
            }
            if groups.isEmpty {
                AINote(L("No usage yet")).padding(.bottom, 20)
            }
            ForEach(Array(groups.enumerated()), id: \.element.name) { index, group in
                let value = UsagePresentation.value(group.totals, metric)
                let unavailable = (metric == .cost && group.totals.unknownCostRequests == group.totals.requests)
                    || (metric == .tokens && group.totals.unknownTokenRequests == group.totals.requests)
                let color = Self.palette[index % Self.palette.count]
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 14) {
                        HStack(spacing: 7) {
                            Circle().fill(color).frame(width: 6, height: 6)
                            Text(verbatim: name(group.name)).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                        Text(verbatim: UsagePresentation.label(group.totals, metric)).monospacedDigit()
                        Text(verbatim: total > 0 && !unavailable ? "\(Int((value / total * 100).rounded()))%" : "—")
                            .font(.system(size: 10))
                            .foregroundStyle(PrismTheme.textMuted)
                            .frame(width: 40, alignment: .trailing)
                            .monospacedDigit()
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(PrismTheme.textSecondary)
                    GeometryReader { geometry in
                        RoundedRectangle(cornerRadius: 3).fill(PrismTheme.surface)
                            .overlay(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 3).fill(color).frame(width: largest > 0 ? geometry.size.width * value / largest : 0)
                            }
                    }
                    .frame(height: 5)
                }
            }
        }
        .padding(.bottom, 4)
    }

    private func name(_ raw: String) -> String {
        switch grouping {
        case .feature: return UsagePresentation.featureName(raw)
        case .provider: return UsagePresentation.providerName(raw)
        case .model:
            let parts = raw.components(separatedBy: " / ")
            guard parts.count > 1 else { return raw }
            return UsagePresentation.providerName(parts[0]) + " / " + parts.dropFirst().joined(separator: " / ")
        }
    }

    // MARK: Details

    private func details(_ summary: UsageSummary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 0) {
                GridRow {
                    Text(L("Feature")); Text(L("Model")); Text(L("Provider"))
                    Text(L("Tokens")).gridColumnAlignment(.trailing); Text(L("Cost")).gridColumnAlignment(.trailing)
                }
                .foregroundStyle(PrismTheme.textMuted)
                .padding(.vertical, 10)
                tableLine
                ForEach(Array(summary.breakdown.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        Text(verbatim: UsagePresentation.featureName(row.feature))
                        Text(verbatim: row.model.isEmpty ? "—" : row.model).lineLimit(1).truncationMode(.middle)
                        Text(verbatim: UsagePresentation.providerName(row.provider))
                        Text(verbatim: row.totals.tokens.formatted() + (row.totals.unknownTokenRequests > 0 ? " + ?" : "")).monospacedDigit()
                        Text(verbatim: UsagePresentation.cost(row.totals)).monospacedDigit()
                    }
                    .foregroundStyle(PrismTheme.textSecondary)
                    .padding(.vertical, 10)
                    tableLine
                }
            }
            .font(.system(size: 11))
            usageLine(L("All time"), detail: nil,
                      value: "\(UsagePresentation.cost(summary.allTime)) · " + L("\(summary.allTime.requests) requests"), valueDetail: nil)
            if !summary.recent.isEmpty {
                AINote(L("Latest 12 requests")).padding(.vertical, 10)
                ForEach(summary.recent) { row in
                    usageLine(UsagePresentation.featureName(row.feature),
                              detail: "\(row.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(UsagePresentation.providerName(row.provider)) · \(row.model)"
                                  + (row.status == "unconfirmed" ? " · " + L("Unconfirmed") : ""),
                              value: UsagePresentation.rowCost(row),
                              valueDetail: row.measurement.inputTokens != nil && row.measurement.outputTokens != nil
                                  ? L("\(row.measurement.inputTokens ?? 0) in / \(row.measurement.outputTokens ?? 0) out")
                                  : L("Tokens unavailable"))
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                AINote(L("Recorded on this device from now on. ≈ is a base-rate estimate; + ? means some costs are unavailable. Interrupted requests may still be billed. Provider invoices may differ."))
                AINote(L("Only usage metadata is saved. No audio or dictated text is stored in usage history."))
            }
            .padding(.top, 12)
        }
    }

    private var tableLine: some View {
        Rectangle().fill(PrismTheme.separator).frame(height: 1).gridCellUnsizedAxes(.horizontal)
    }

    /// One `.ai-usage-line`: label and value with optional muted second lines, above a hairline.
    private func usageLine(_ title: String, detail: String?, value: String, valueDetail: String?) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: title)
                if let detail {
                    Text(verbatim: detail).font(.system(size: 10)).foregroundStyle(PrismTheme.textMuted).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 4) {
                Text(verbatim: value).monospacedDigit()
                if let valueDetail { Text(verbatim: valueDetail).font(.system(size: 10)).foregroundStyle(PrismTheme.textMuted) }
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(PrismTheme.text)
        .padding(.vertical, 10)
        .overlay(alignment: .top) { PrismHairline() }
    }
}

/// The Tauri daily chart: three dashed guides, the maximum at the top right, a soft area under a 2.5 pt line,
/// dots on active days and day labels 1 · middle · last. Hovering a day reports its index.
private struct UsageTimeline: View {
    let count: Int
    let values: [Double]
    let maximum: Double
    @Binding var hovered: Int?
    let showsLine: Bool
    let showsPoints: Bool
    let requests: [Int]
    let maximumLabel: String

    private static let tint = AIUsageSection.palette[0]
    private static let height: CGFloat = 155

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let scale = width / 620
            let x = { (index: Int) -> CGFloat in (18 + CGFloat(index) / CGFloat(max(count - 1, 1)) * 584) * scale }
            let y = { (value: Double) -> CGFloat in 126 - (maximum > 0 ? CGFloat(value / maximum) * 102 : 0) }
            ZStack(alignment: .topLeading) {
                ForEach([24, 75, 126] as [CGFloat], id: \.self) { position in
                    Path { path in
                        path.move(to: CGPoint(x: 18 * scale, y: position))
                        path.addLine(to: CGPoint(x: 602 * scale, y: position))
                    }
                    .stroke(PrismTheme.lineStrong, style: StrokeStyle(lineWidth: 1, dash: [3, 5]))
                }
                Text(verbatim: maximumLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(PrismTheme.textMuted)
                    .frame(width: 602 * scale, alignment: .trailing)
                    .offset(y: 3)
                if showsLine, !values.isEmpty {
                    let line = Path { path in
                        for (index, value) in values.enumerated() {
                            let point = CGPoint(x: x(index), y: y(value))
                            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                        }
                    }
                    let area = Path { path in
                        path.addPath(line)
                        path.addLine(to: CGPoint(x: x(values.count - 1), y: 126))
                        path.addLine(to: CGPoint(x: x(0), y: 126))
                        path.closeSubpath()
                    }
                    area.fill(LinearGradient(colors: [Self.tint.opacity(0.27), Self.tint.opacity(0.015)], startPoint: .top, endPoint: .bottom))
                    line.stroke(Self.tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                }
                if showsPoints {
                    ForEach(values.indices, id: \.self) { index in
                        if requests[index] > 0 || hovered == index {
                            let radius: CGFloat = hovered == index ? 4 : 2.5
                            Circle().fill(Self.tint)
                                .frame(width: radius * 2, height: radius * 2)
                                .position(x: x(index), y: y(values[index]))
                        }
                    }
                }
                ForEach(axisIndices, id: \.self) { index in
                    Text(verbatim: "\(index + 1)")
                        .font(.system(size: 10))
                        .foregroundStyle(PrismTheme.textMuted)
                        .fixedSize()
                        .position(x: x(index) + (index == 0 ? 3 : index == count - 1 ? -5 : 0), y: 146)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    guard count > 1 else { return }
                    let raw = (location.x / scale - 18) / 584 * CGFloat(count - 1)
                    let index = Int(raw.rounded())
                    hovered = values.indices.contains(index) ? index : nil
                case .ended:
                    hovered = nil
                }
            }
        }
        .frame(height: Self.height)
    }

    private var axisIndices: [Int] {
        guard count > 0 else { return [] }
        return Array(Set([0, (count - 1) / 2, count - 1])).sorted()
    }
}
