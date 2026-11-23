import AgentGridShared
import SwiftUI

/// 状态态：左侧额度（5H / 7D），右侧近期 Token 用量柱状图。
struct UsageDashboardView: View {
    let codex: UsageSnapshot?
    let claude: UsageSnapshot?
    let connected: Bool
    let compact: Bool

    @State private var selectedRange: UsageRange = .sevenDays
    /// nil 表示用户尚未手动选择，跟随数据自动挑选默认提供方。
    @State private var selectedProvider: UsageProvider?

    private var provider: UsageProvider {
        selectedProvider ?? UsagePresentation.defaultProvider(codex: codex, claude: claude)
    }

    var body: some View {
        let usage = provider.pick(codex: codex, claude: claude)
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let quota = QuotaPanel(provider: provider, usage: usage, now: context.date, connected: connected)
            let history = HistoryPanel(
                provider: provider,
                onProviderSelected: { selectedProvider = $0 },
                allPoints: usage?.dailyUsage ?? [],
                selectedRange: $selectedRange
            )
            ScrollView {
                Group {
                    if compact {
                        VStack(alignment: .leading, spacing: 20) {
                            quota
                            Rectangle().fill(PixelTheme.divider).frame(height: 1)
                            history
                        }
                    } else {
                        HStack(alignment: .top, spacing: 24) {
                            quota.frame(width: 270)
                            Rectangle().fill(PixelTheme.divider).frame(width: 1)
                            history.frame(maxWidth: .infinity)
                        }
                    }
                }
                .padding(.horizontal, compact ? 20 : 36)
                .padding(.vertical, 12)
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
        }
    }
}

private struct QuotaPanel: View {
    let provider: UsageProvider
    let usage: UsageSnapshot?
    let now: Date
    let connected: Bool

    var body: some View {
        let windows = UsagePresentation.pickWindows(usage?.windows ?? [])
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 10) {
                PixelCoreView(lifecycle: connected ? .idle : .offline, activity: nil, changedAt: .distantPast)
                    .frame(width: 42, height: 42)
                    .accessibilityLabel("\(provider.displayName) \(connected ? "空闲" : "离线")")
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(provider.displayName.uppercased()) 额度")
                        .font(.pixel(14, weight: .bold))
                        .foregroundStyle(PixelTheme.text)
                    Text(planText)
                        .font(.pixel(11))
                        .foregroundStyle(PixelTheme.muted)
                }
            }

            primary(
                UsagePresentation.display(windows.primary, fallbackLabel: "5H", now: now),
                resetText: windows.primary == nil && provider == .claude
                    ? "需在 Claude Code CLI 中使用，并在 Mac 端安装 Hook"
                    : UsagePresentation.quotaResetText(windows.primary, now: now)
            )
            secondary(
                UsagePresentation.display(windows.secondary, fallbackLabel: "7D", now: now),
                resetText: UsagePresentation.quotaResetText(windows.secondary, now: now)
            )

            Text(UsagePresentation.freshnessText(usage?.capturedAt, now: now) + (connected ? "" : " · Bridge 离线"))
                .font(.pixel(11))
                .foregroundStyle(connected ? PixelTheme.dimmed : PixelTheme.red)
        }
    }

    private var planText: String {
        if let plan = usage?.planType, !plan.trimmingCharacters(in: .whitespaces).isEmpty {
            return "\(plan.uppercased()) 计划"
        }
        return "订阅计划"
    }

    private func primary(_ display: QuotaDisplay, resetText: String) -> some View {
        let color = PixelTheme.quotaColor(display.remaining)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text(display.remaining.map { "\($0)%" } ?? "--%")
                    .font(.pixel(42, weight: .bold))
                    .foregroundStyle(color)
                Text("\(display.label.uppercased()) 剩余")
                    .font(.pixel(11))
                    .foregroundStyle(PixelTheme.muted)
            }
            QuotaBar(fraction: Double(display.remaining ?? 0) / 100, color: color, height: 5)
                .accessibilityLabel(display.remaining.map { "主要额度剩余 \($0)%" } ?? "主要额度剩余未知")
            Text(resetText)
                .font(.pixel(11))
                .foregroundStyle(PixelTheme.muted)
        }
    }

    private func secondary(_ display: QuotaDisplay, resetText: String) -> some View {
        let color = PixelTheme.quotaColor(display.remaining)
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("\(display.label.uppercased()) 额度")
                    .font(.pixel(11))
                    .foregroundStyle(PixelTheme.muted)
                Spacer()
                Text(display.remaining.map { "\($0)% 剩余" } ?? "--% 剩余")
                    .font(.pixel(12, weight: .bold))
                    .foregroundStyle(color)
            }
            QuotaBar(fraction: Double(display.remaining ?? 0) / 100, color: color, height: 3)
                .accessibilityLabel(display.remaining.map { "次要额度剩余 \($0)%" } ?? "次要额度剩余未知")
            Text(resetText)
                .font(.pixel(11))
                .foregroundStyle(PixelTheme.dimmed)
        }
    }
}

private struct HistoryPanel: View {
    let provider: UsageProvider
    let onProviderSelected: (UsageProvider) -> Void
    let allPoints: [DailyUsagePoint]
    @Binding var selectedRange: UsageRange

    var body: some View {
        let points = UsagePresentation.points(allPoints, range: selectedRange)
        let totalTokens = UsagePresentation.totalTokens(points)
        let cost = UsagePresentation.totalEstimatedCostUSD(points)
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(provider.displayName) 近期用量")
                        .font(.pixel(13, weight: .bold))
                        .foregroundStyle(PixelTheme.text)
                    Text(cost == nil ? "\(selectedRange.days) 天合计" : "\(selectedRange.days) 天 · API 价预估")
                        .font(.pixel(11))
                        .foregroundStyle(PixelTheme.muted)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(cost == nil
                        ? UsagePresentation.compactTokens(totalTokens)
                        : UsagePresentation.estimatedCostUSD(cost))
                        .font(.pixel(24, weight: .bold))
                        .foregroundStyle(PixelTheme.cyan)
                    Text(cost == nil ? "TOKEN" : "\(UsagePresentation.compactTokens(totalTokens)) TOKEN")
                        .font(.pixel(10))
                        .tracking(1)
                        .foregroundStyle(PixelTheme.dimmed)
                }
            }

            HStack {
                Segmented(
                    options: UsageProvider.allCases,
                    selection: provider,
                    title: { $0.displayName.uppercased() },
                    color: { PixelTheme.color($0) },
                    onSelect: onProviderSelected
                )
                Spacer(minLength: 8)
                Segmented(
                    options: UsageRange.allCases,
                    selection: selectedRange,
                    title: { $0.label },
                    color: { _ in PixelTheme.cyan },
                    onSelect: { selectedRange = $0 }
                )
            }

            UsageBars(points: points)
                .frame(height: 132)
                .animation(.easeOut(duration: 0.15), value: selectedRange)
        }
    }
}

private struct Segmented<Option: Hashable & Identifiable>: View {
    let options: [Option]
    let selection: Option
    let title: (Option) -> String
    let color: (Option) -> Color
    let onSelect: (Option) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options) { option in
                let selected = option == selection
                Button { onSelect(option) } label: {
                    Text(title(option))
                        .font(.pixel(11, weight: selected ? .bold : .regular))
                        .foregroundStyle(selected ? color(option) : PixelTheme.muted)
                        .padding(.horizontal, 10)
                        .frame(minWidth: 48, minHeight: 44)
                        .background(selected ? PixelTheme.raised : .clear)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title(option))
            }
        }
        .background(PixelTheme.surface)
    }
}

private struct UsageBars: View {
    let points: [DailyUsagePoint]

    var body: some View {
        let hasUsage = points.contains { $0.totalTokens > 0 }
        VStack(spacing: 6) {
            ZStack {
                Canvas { context, size in
                    let baseline = size.height - 1
                    context.fill(Path(CGRect(x: 0, y: baseline, width: size.width, height: 1)), with: .color(PixelTheme.divider))
                    guard hasUsage, !points.isEmpty else { return }

                    let maximum = Double(max(1, points.map(\.totalTokens).max() ?? 1))
                    let slot = size.width / CGFloat(points.count)
                    let gap: CGFloat = points.count <= 7 ? 6 : (points.count <= 30 ? 2 : 1)
                    let barWidth = max(1, slot - gap)
                    for (index, point) in points.enumerated() where point.totalTokens > 0 {
                        let ratio = Double(point.totalTokens) / maximum
                        let height = max(1, baseline * ratio)
                        let color: Color = index == points.count - 1
                            ? PixelTheme.cyan
                            : (ratio >= 0.5 ? PixelTheme.usageBar : PixelTheme.usageBarDimmed)
                        let rect = CGRect(
                            x: CGFloat(index) * slot + (slot - barWidth) / 2,
                            y: baseline - height,
                            width: barWidth,
                            height: height
                        )
                        context.fill(Path(rect), with: .color(color))
                    }
                }
                if !hasUsage {
                    Text("暂无近 \(max(points.count, 7)) 天用量")
                        .font(.pixel(11))
                        .foregroundStyle(PixelTheme.dimmed)
                }
            }
            .accessibilityLabel(hasUsage ? "近期 Token 用量柱状图，共 \(points.count) 天" : "暂无近期 Token 用量")

            HStack {
                let labels = [
                    points.first?.date,
                    points.isEmpty ? nil : points[(points.count - 1) / 2].date,
                    points.last?.date,
                ]
                ForEach(Array(labels.enumerated()), id: \.offset) { index, date in
                    if index > 0 { Spacer() }
                    Text(date.map(UsagePresentation.dateLabel) ?? "--/--")
                        .font(.pixel(10))
                        .foregroundStyle(PixelTheme.dimmed)
                }
            }
        }
    }
}
