package com.agentgrid.mobile.ui

import com.agentgrid.mobile.domain.DailyUsagePoint
import com.agentgrid.mobile.domain.UsageSnapshot
import com.agentgrid.mobile.domain.UsageWindow
import java.time.Instant
import java.time.ZoneId
import org.junit.Assert.assertEquals
import org.junit.Test

class UsagePresentationTest {
    @Test
    fun `时间段切换只保留所选天数`() {
        val points = (1..90).map { index ->
            DailyUsagePoint(
                date = "2026-07-${index.toString().padStart(2, '0')}",
                totalTokens = index.toLong(),
            )
        }

        val sevenDays = UsagePresentation.pointsForRange(
            points,
            UsageRange.SEVEN_DAYS,
        )
        val thirtyDays = UsagePresentation.pointsForRange(
            points,
            UsageRange.THIRTY_DAYS,
        )

        assertEquals(7, sevenDays.size)
        assertEquals(84L, sevenDays.first().totalTokens)
        assertEquals(30, thirtyDays.size)
        assertEquals(61L, thirtyDays.first().totalTokens)
    }

    @Test
    fun `Token 汇总使用长整型并按量级压缩`() {
        val points = listOf(
            DailyUsagePoint(date = "2026-07-25", totalTokens = 900_000_000),
            DailyUsagePoint(date = "2026-07-26", totalTokens = 600_000_000),
        )

        val total = UsagePresentation.totalTokens(points)

        assertEquals(1_500_000_000L, total)
        assertEquals("1.5B", UsagePresentation.compactTokens(total))
    }

    @Test
    fun `美元预估只汇总有价格的数据并按量级显示`() {
        val points = listOf(
            DailyUsagePoint(
                date = "2026-07-25",
                estimatedCostUSD = 120.2,
            ),
            DailyUsagePoint(
                date = "2026-07-26",
                estimatedCostUSD = 271.7,
            ),
        )

        val total = UsagePresentation.totalEstimatedCostUSD(points)

        assertEquals(391.9, total!!, 0.0001)
        assertEquals("$392", UsagePresentation.estimatedCostUSD(total))
        assertEquals("$1.2K", UsagePresentation.estimatedCostUSD(1_249.0))
        assertEquals(
            null,
            UsagePresentation.totalEstimatedCostUSD(
                listOf(DailyUsagePoint(date = "2026-07-26")),
            ),
        )
    }

    @Test
    fun `额度重置同时支持倒计时和具体日期`() {
        val now = Instant.parse("2026-07-26T12:00:00Z").toEpochMilli()

        assertEquals(
            "2 小时 15 分后重置",
            UsagePresentation.resetText(
                resetsAt = now + (2 * 60 + 15) * 60_000L,
                now = now,
                zoneId = ZoneId.of("UTC"),
            ),
        )
        assertEquals(
            "07月29日 12:00 重置",
            UsagePresentation.resetText(
                resetsAt = now + 3 * 24 * 60 * 60_000L,
                now = now,
                zoneId = ZoneId.of("UTC"),
            ),
        )
    }

    private val now = Instant.parse("2026-07-26T12:00:00Z").toEpochMilli()

    private fun window(
        key: String,
        remaining: Double = 80.0,
        resetsAt: Long? = null,
        label: String = key,
    ) = UsageWindow(
        key = key,
        label = label,
        usedPercentage = 100 - remaining,
        remainingPercentage = remaining,
        windowMinutes = 300,
        resetsAt = resetsAt,
    )

    @Test
    fun `主次窗口按 key 选择且不会把次窗口当作主窗口重复展示`() {
        val primary = window("primary")
        val secondary = window("secondary")

        assertEquals(primary to secondary, UsagePresentation.pickWindows(listOf(secondary, primary)))
        assertEquals(primary to null, UsagePresentation.pickWindows(listOf(primary)))
        assertEquals(null to secondary, UsagePresentation.pickWindows(listOf(secondary)))
        assertEquals(null to null, UsagePresentation.pickWindows(emptyList()))
        val other = window("weekly")
        assertEquals(other to null, UsagePresentation.pickWindows(listOf(other)))
    }

    @Test
    fun `重置时间已过去的窗口显示为未知而不是旧百分比`() {
        val stale = window("primary", remaining = 3.0, resetsAt = now - 1, label = "5h")
        val live = window("primary", remaining = 41.6, resetsAt = now + 60_000, label = "5h")
        val noReset = window("primary", remaining = 55.0, resetsAt = null, label = "5h")

        assertEquals(null, UsagePresentation.display(stale, "5H", now).remaining)
        assertEquals(true, UsagePresentation.display(stale, "5H", now).expired)
        assertEquals(42, UsagePresentation.display(live, "5H", now).remaining)
        assertEquals(55, UsagePresentation.display(noReset, "5H", now).remaining)
        assertEquals("已重置 · 等待更新", UsagePresentation.quotaResetText(stale, now))
        assertEquals("暂无额度数据", UsagePresentation.quotaResetText(null, now))
        assertEquals("重置时间未知", UsagePresentation.quotaResetText(noReset, now))
    }

    @Test
    fun `缺失窗口和非法百分比被钳制或视为未知`() {
        assertEquals(true, UsagePresentation.display(null, "7D", now).missing)
        assertEquals("7D", UsagePresentation.display(null, "7D", now).label)
        assertEquals(100, UsagePresentation.display(window("primary", 140.0), "5H", now).remaining)
        assertEquals(0, UsagePresentation.display(window("primary", -5.0), "5H", now).remaining)
        assertEquals(
            null,
            UsagePresentation.display(window("primary", Double.NaN), "5H", now).remaining,
        )
        assertEquals("5H", UsagePresentation.display(window("primary", label = " "), "5H", now).label)
    }

    @Test
    fun `默认提供方优先有额度窗口的一方`() {
        val withWindows = UsageSnapshot(windows = listOf(window("primary")))
        val onlyDaily = UsageSnapshot(dailyUsage = listOf(DailyUsagePoint(date = "2026-07-26")))

        assertEquals(UsageProvider.CODEX, UsagePresentation.defaultProvider(null, null))
        assertEquals(UsageProvider.CODEX, UsagePresentation.defaultProvider(withWindows, withWindows))
        assertEquals(UsageProvider.CLAUDE, UsagePresentation.defaultProvider(onlyDaily, withWindows))
        assertEquals(UsageProvider.CLAUDE, UsagePresentation.defaultProvider(null, onlyDaily))
        assertEquals(UsageProvider.CODEX, UsagePresentation.defaultProvider(onlyDaily, UsageSnapshot()))
    }

    @Test
    fun `提供方按枚举选择对应额度`() {
        val codex = UsageSnapshot(planType = "plus")
        val claude = UsageSnapshot(planType = "max")

        assertEquals(codex, UsageProvider.CODEX.pick(codex, claude))
        assertEquals(claude, UsageProvider.CLAUDE.pick(codex, claude))
        assertEquals(null, UsageProvider.CLAUDE.pick(codex, null))
    }

    @Test
    fun `Claude 只有 token 没有美元预估时汇总为空美元`() {
        val points = listOf(
            DailyUsagePoint(date = "2026-07-25", totalTokens = 1_200_000),
            DailyUsagePoint(date = "2026-07-26", totalTokens = 300_000),
        )

        assertEquals(null, UsagePresentation.totalEstimatedCostUSD(points))
        assertEquals("1.5M", UsagePresentation.compactTokens(UsagePresentation.totalTokens(points)))
    }
}
