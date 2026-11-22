package com.agentgrid.mobile.ui

import com.agentgrid.mobile.domain.DailyUsagePoint
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
    fun `partial local reads suppress cost but retain available tokens`() {
        val points = listOf(DailyUsagePoint(date = "2026-11-21", totalTokens = 1200, estimatedCostUSD = 0.25))
        assertEquals(null, UsagePresentation.totalEstimatedCostUSD(points, isPartial = true))
        assertEquals(0.25, UsagePresentation.totalEstimatedCostUSD(points, isPartial = false)!!, 0.0001)
        assertEquals(1200L, UsagePresentation.totalTokens(points))
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
}
