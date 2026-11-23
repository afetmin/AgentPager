import Foundation
import Testing
@testable import AgentGridShared

private let base = Date(timeIntervalSince1970: 1_785_067_200)  // 2026-07-26T12:00:00Z
private let utc = TimeZone(identifier: "UTC")!

private func window(
    _ key: String,
    remaining: Double = 80,
    resetsAt: Date? = nil,
    label: String? = nil
) -> UsageWindow {
    UsageWindow(
        key: key,
        label: label ?? key,
        usedPercentage: 100 - remaining,
        remainingPercentage: remaining,
        windowMinutes: 300,
        resetsAt: resetsAt
    )
}

@Test("时间段切换只保留所选天数")
func rangeKeepsLastDays() {
    let points = (1...90).map { DailyUsagePoint(date: "2026-07-\($0)", totalTokens: Int64($0)) }

    let seven = UsagePresentation.points(points, range: .sevenDays)
    let thirty = UsagePresentation.points(points, range: .thirtyDays)

    #expect(seven.count == 7)
    #expect(seven.first?.totalTokens == 84)
    #expect(thirty.count == 30)
    #expect(thirty.first?.totalTokens == 61)
}

@Test("Token 汇总使用 64 位整数并按量级压缩")
func tokenTotals() {
    let points = [
        DailyUsagePoint(date: "2026-07-25", totalTokens: 900_000_000),
        DailyUsagePoint(date: "2026-07-26", totalTokens: 600_000_000),
    ]
    let total = UsagePresentation.totalTokens(points)

    #expect(total == 1_500_000_000)
    #expect(UsagePresentation.compactTokens(total) == "1.5B")
    #expect(UsagePresentation.compactTokens(2_000_000) == "2M")
    #expect(UsagePresentation.compactTokens(1_250) == "1.3K")
    #expect(UsagePresentation.compactTokens(999) == "999")
}

@Test("美元预估只汇总有价格的数据并按量级显示")
func costTotals() throws {
    let points = [
        DailyUsagePoint(date: "2026-07-25", estimatedCostUSD: 120.2),
        DailyUsagePoint(date: "2026-07-26", estimatedCostUSD: 271.7),
    ]
    let total = try #require(UsagePresentation.totalEstimatedCostUSD(points))

    #expect(abs(total - 391.9) < 0.0001)
    #expect(UsagePresentation.estimatedCostUSD(total) == "$392")
    #expect(UsagePresentation.estimatedCostUSD(1_249) == "$1.2K")
    #expect(UsagePresentation.estimatedCostUSD(12.34) == "$12.3")
    #expect(UsagePresentation.estimatedCostUSD(1.5) == "$1.50")
    #expect(UsagePresentation.estimatedCostUSD(nil) == "--")
    #expect(UsagePresentation.totalEstimatedCostUSD([DailyUsagePoint(date: "2026-07-26")]) == nil)
}

@Test("额度重置同时支持倒计时和具体日期")
func resetText() {
    #expect(
        UsagePresentation.resetText(base.addingTimeInterval((2 * 60 + 15) * 60), now: base, timeZone: utc)
            == "2 小时 15 分后重置"
    )
    #expect(
        UsagePresentation.resetText(base.addingTimeInterval(3 * 24 * 3_600), now: base, timeZone: utc)
            == "07月29日 12:00 重置"
    )
    #expect(UsagePresentation.resetText(base.addingTimeInterval(30), now: base) == "1 分后重置")
    #expect(UsagePresentation.resetText(base.addingTimeInterval(3 * 3_600), now: base) == "3 小时后重置")
    #expect(UsagePresentation.resetText(base, now: base) == "即将重置")
}

@Test("主次窗口按 key 选择且不会把次窗口当作主窗口重复展示")
func pickWindows() {
    let primary = window("primary")
    let secondary = window("secondary")
    let other = window("weekly")

    #expect(UsagePresentation.pickWindows([secondary, primary]) == (primary, secondary))
    #expect(UsagePresentation.pickWindows([primary]) == (primary, nil))
    #expect(UsagePresentation.pickWindows([secondary]) == (nil, secondary))
    #expect(UsagePresentation.pickWindows([]) == (nil, nil))
    #expect(UsagePresentation.pickWindows([other]) == (other, nil))
}

@Test("重置时间已过去的窗口显示为未知而不是旧百分比")
func expiredWindowsAreUnknown() {
    let stale = window("primary", remaining: 3, resetsAt: base.addingTimeInterval(-1), label: "5h")
    let live = window("primary", remaining: 41.6, resetsAt: base.addingTimeInterval(60), label: "5h")
    let noReset = window("primary", remaining: 55, label: "5h")

    #expect(UsagePresentation.display(stale, fallbackLabel: "5H", now: base).remaining == nil)
    #expect(UsagePresentation.display(stale, fallbackLabel: "5H", now: base).expired)
    #expect(UsagePresentation.display(live, fallbackLabel: "5H", now: base).remaining == 42)
    #expect(UsagePresentation.display(noReset, fallbackLabel: "5H", now: base).remaining == 55)
    #expect(UsagePresentation.quotaResetText(stale, now: base) == "已重置 · 等待更新")
    #expect(UsagePresentation.quotaResetText(nil, now: base) == "暂无额度数据")
    #expect(UsagePresentation.quotaResetText(noReset, now: base) == "重置时间未知")
}

@Test("缺失窗口和非法百分比被钳制或视为未知")
func displayClamps() {
    #expect(UsagePresentation.display(nil, fallbackLabel: "7D", now: base)
        == QuotaDisplay(label: "7D", remaining: nil, expired: false, missing: true))
    #expect(UsagePresentation.display(window("primary", remaining: 140), fallbackLabel: "5H", now: base).remaining == 100)
    #expect(UsagePresentation.display(window("primary", remaining: -5), fallbackLabel: "5H", now: base).remaining == 0)
    #expect(UsagePresentation.display(window("primary", remaining: .nan), fallbackLabel: "5H", now: base).remaining == nil)
    #expect(UsagePresentation.display(window("primary", label: ""), fallbackLabel: "5H", now: base).label == "5H")
}

@Test("默认提供方优先有额度窗口的一方")
func defaultProvider() {
    let withWindows = UsageSnapshot(capturedAt: nil, planType: nil, limitID: nil, windows: [window("primary")])
    let withDaily = UsageSnapshot(
        capturedAt: nil, planType: nil, limitID: nil, windows: [],
        dailyUsage: [DailyUsagePoint(date: "2026-07-26", totalTokens: 1)]
    )

    #expect(UsagePresentation.defaultProvider(codex: withWindows, claude: withWindows) == .codex)
    #expect(UsagePresentation.defaultProvider(codex: nil, claude: withWindows) == .claude)
    #expect(UsagePresentation.defaultProvider(codex: withDaily, claude: withWindows) == .claude)
    #expect(UsagePresentation.defaultProvider(codex: nil, claude: withDaily) == .claude)
    #expect(UsagePresentation.defaultProvider(codex: nil, claude: nil) == .codex)
    #expect(UsageProvider.claude.pick(codex: withDaily, claude: withWindows) == withWindows)
}

@Test("更新时间文案按量级换算")
func freshness() {
    #expect(UsagePresentation.freshnessText(nil, now: base) == "等待用量数据")
    #expect(UsagePresentation.freshnessText(base.addingTimeInterval(-20), now: base) == "刚刚更新")
    #expect(UsagePresentation.freshnessText(base.addingTimeInterval(-5 * 60), now: base) == "5 分钟前更新")
    #expect(UsagePresentation.freshnessText(base.addingTimeInterval(-3 * 3_600), now: base) == "3 小时前更新")
    #expect(UsagePresentation.freshnessText(base.addingTimeInterval(-2 * 86_400), now: base) == "2 天前更新")
    #expect(UsagePresentation.dateLabel("2026-07-26") == "07/26")
}

@Test("任务行文案与格式化")
func taskPresentation() {
    var task = TaskSnapshot(id: "t", source: .claudeCode, projectName: "P", lifecycle: .running, activity: .testing)
    #expect(TaskPresentation.statusText(task) == "正在测试")
    task.lifecycle = .waitingApproval
    #expect(TaskPresentation.statusText(task) == "等待批准")
    #expect(TaskPresentation.agentBadge(task) == "Claude")
    #expect(TaskPresentation.agentOrigin(task) == "Claude Code")
    task.agentName = "ZCode"
    #expect(TaskPresentation.agentBadge(task) == "ZCode")
    #expect(TaskPresentation.agentOrigin(task) == "Hook")
    #expect(TaskPresentation.elapsedText(65) == "01:05")
    #expect(TaskPresentation.elapsedText(3_725) == "1:02:05")
    #expect(TaskPresentation.tokensText(nil) == "— tok")
    #expect(TaskPresentation.tokensText(1_500) == "1.5k tok")
    #expect(TaskPresentation.tokensText(2_500_000) == "2.5m tok")
    #expect(TaskPresentation.shouldShowTokenSummary(task) == false)
}
