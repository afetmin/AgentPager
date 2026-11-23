import Foundation

public enum UsageRange: Int, CaseIterable, Identifiable, Sendable {
    case sevenDays = 7
    case thirtyDays = 30
    case ninetyDays = 90

    public var id: Int { rawValue }
    public var days: Int { rawValue }
    public var label: String { "\(rawValue) 天" }
}

/// 额度所属的 Agent 提供方。
public enum UsageProvider: String, CaseIterable, Identifiable, Sendable {
    case codex
    case claude

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        }
    }

    /// 顶栏小号额度条的前缀，必须足够短。
    public var shortName: String {
        switch self {
        case .codex: "CDX"
        case .claude: "CLD"
        }
    }

    public func pick(codex: UsageSnapshot?, claude: UsageSnapshot?) -> UsageSnapshot? {
        switch self {
        case .codex: codex
        case .claude: claude
        }
    }
}

/// 一个额度窗口在界面上的展示结果。`remaining == nil` 表示未知或已过期。
public struct QuotaDisplay: Equatable, Sendable {
    public var label: String
    public var remaining: Int?
    public var expired: Bool
    public var missing: Bool
}

public enum UsagePresentation {
    /// 订阅额度窗口：primary 为短窗口（5h），secondary 为长窗口（7d）。
    public static func pickWindows(_ windows: [UsageWindow]) -> (primary: UsageWindow?, secondary: UsageWindow?) {
        let secondary = windows.first { $0.key == "secondary" }
        let primary = windows.first { $0.key == "primary" }
            ?? windows.first { $0.key != secondary?.key }
        return (primary, secondary)
    }

    /// 默认展示哪个提供方：优先有额度窗口的，其次有用量数据的，最后回退 Codex。
    public static func defaultProvider(codex: UsageSnapshot?, claude: UsageSnapshot?) -> UsageProvider {
        if codex?.windows.isEmpty == false { return .codex }
        if claude?.windows.isEmpty == false { return .claude }
        if codex?.dailyUsage.isEmpty == false { return .codex }
        if claude?.dailyUsage.isEmpty == false { return .claude }
        return .codex
    }

    /// 重置时间已过去的窗口，其百分比是上一个周期的旧值，不能再当作当前额度展示。
    public static func isExpired(_ window: UsageWindow, now: Date = .now) -> Bool {
        window.resetsAt.map { $0 <= now } ?? false
    }

    public static func display(_ window: UsageWindow?, fallbackLabel: String, now: Date = .now) -> QuotaDisplay {
        guard let window else {
            return QuotaDisplay(label: fallbackLabel, remaining: nil, expired: false, missing: true)
        }
        let expired = isExpired(window, now: now)
        let remaining: Int? = window.remainingPercentage.isFinite && !expired
            ? min(100, max(0, Int(window.remainingPercentage.rounded())))
            : nil
        return QuotaDisplay(
            label: window.label.isEmpty ? fallbackLabel : window.label,
            remaining: remaining,
            expired: expired,
            missing: false
        )
    }

    public static func quotaResetText(
        _ window: UsageWindow?,
        now: Date = .now,
        timeZone: TimeZone = .current
    ) -> String {
        guard let window else { return "暂无额度数据" }
        if isExpired(window, now: now) { return "已重置 · 等待更新" }
        return resetText(window.resetsAt, now: now, timeZone: timeZone)
    }

    public static func resetText(
        _ resetsAt: Date?,
        now: Date = .now,
        timeZone: TimeZone = .current
    ) -> String {
        guard let resetsAt else { return "重置时间未知" }
        let remaining = resetsAt.timeIntervalSince(now)
        if remaining <= 0 { return "即将重置" }

        let minutes = max(1, Int((remaining / 60).rounded(.up)))
        if minutes < 60 { return "\(minutes) 分后重置" }

        let hours = minutes / 60
        let rest = minutes % 60
        if hours < 24 {
            return rest == 0 ? "\(hours) 小时后重置" : "\(hours) 小时 \(rest) 分后重置"
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = timeZone
        formatter.dateFormat = "MM月dd日 HH:mm"
        return formatter.string(from: resetsAt) + " 重置"
    }

    public static func freshnessText(_ capturedAt: Date?, now: Date = .now) -> String {
        guard let capturedAt else { return "等待用量数据" }
        let minutes = Int(max(0, now.timeIntervalSince(capturedAt)) / 60)
        switch minutes {
        case ..<1: return "刚刚更新"
        case ..<60: return "\(minutes) 分钟前更新"
        case ..<(24 * 60): return "\(minutes / 60) 小时前更新"
        default: return "\(minutes / (24 * 60)) 天前更新"
        }
    }

    public static func points(_ points: [DailyUsagePoint], range: UsageRange) -> [DailyUsagePoint] {
        Array(points.suffix(range.days))
    }

    public static func totalTokens(_ points: [DailyUsagePoint]) -> Int64 {
        points.reduce(0) { $0 + $1.totalTokens }
    }

    public static func totalEstimatedCostUSD(_ points: [DailyUsagePoint]) -> Double? {
        let costs = points.compactMap(\.estimatedCostUSD)
        return costs.isEmpty ? nil : costs.reduce(0, +)
    }

    public static func compactTokens(_ value: Int64) -> String {
        switch value {
        case 1_000_000_000...: decimal(Double(value) / 1_000_000_000) + "B"
        case 1_000_000...: decimal(Double(value) / 1_000_000) + "M"
        case 1_000...: decimal(Double(value) / 1_000) + "K"
        default: String(max(0, value))
        }
    }

    public static func estimatedCostUSD(_ value: Double?) -> String {
        guard let value else { return "--" }
        let safe = max(0, value)
        switch safe {
        case 1_000...: return "$" + decimal(safe / 1_000) + "K"
        case 100...: return String(format: "$%.0f", safe)
        case 10...: return String(format: "$%.1f", safe)
        default: return String(format: "$%.2f", safe)
        }
    }

    /// `2026-07-26` → `07/26`。
    public static func dateLabel(_ date: String) -> String {
        let parts = date.split(separator: "-")
        guard parts.count == 3 else { return date }
        return "\(parts[1])/\(parts[2])"
    }

    private static func decimal(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int64(rounded))
            : String(format: "%.1f", rounded)
    }
}
