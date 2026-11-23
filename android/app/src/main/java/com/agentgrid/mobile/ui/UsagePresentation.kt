package com.agentgrid.mobile.ui

import com.agentgrid.mobile.domain.DailyUsagePoint
import com.agentgrid.mobile.domain.UsageSnapshot
import com.agentgrid.mobile.domain.UsageWindow
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import kotlin.math.ceil
import kotlin.math.roundToInt

internal enum class UsageRange(
    val days: Int,
    val label: String,
) {
    SEVEN_DAYS(7, "7 天"),
    THIRTY_DAYS(30, "30 天"),
    NINETY_DAYS(90, "90 天"),
}

/** 额度所属的 Agent 提供方。 */
internal enum class UsageProvider(
    val displayName: String,
    /** 顶栏小号额度条的前缀，必须足够短。 */
    val shortName: String,
) {
    CODEX("Codex", "CDX"),
    CLAUDE("Claude", "CLD"),
}

internal fun UsageProvider.pick(
    codex: UsageSnapshot?,
    claude: UsageSnapshot?,
): UsageSnapshot? = when (this) {
    UsageProvider.CODEX -> codex
    UsageProvider.CLAUDE -> claude
}

/** 一个额度窗口在界面上的展示结果。`remaining == null` 表示未知或已过期。 */
internal data class QuotaDisplay(
    val label: String,
    val remaining: Int?,
    val expired: Boolean,
    val missing: Boolean,
)

internal object UsagePresentation {
    /** 订阅额度窗口：primary 为短窗口（5h），secondary 为长窗口（7d）。 */
    fun pickWindows(windows: List<UsageWindow>): Pair<UsageWindow?, UsageWindow?> {
        val secondary = windows.firstOrNull { it.key == "secondary" }
        val primary = windows.firstOrNull { it.key == "primary" }
            ?: windows.firstOrNull { it !== secondary }
        return primary to secondary
    }

    /** 默认展示哪个提供方：优先有额度窗口的，其次有用量数据的，最后回退 Codex。 */
    fun defaultProvider(codex: UsageSnapshot?, claude: UsageSnapshot?): UsageProvider = when {
        codex?.windows?.isNotEmpty() == true -> UsageProvider.CODEX
        claude?.windows?.isNotEmpty() == true -> UsageProvider.CLAUDE
        codex?.dailyUsage?.isNotEmpty() == true -> UsageProvider.CODEX
        claude?.dailyUsage?.isNotEmpty() == true -> UsageProvider.CLAUDE
        else -> UsageProvider.CODEX
    }

    /** 重置时间已过去的窗口，其百分比是上一个周期的旧值，不能再当作当前额度展示。 */
    fun isExpired(window: UsageWindow, now: Long = System.currentTimeMillis()): Boolean =
        window.resetsAt?.let { it <= now } == true

    fun display(
        window: UsageWindow?,
        fallbackLabel: String,
        now: Long = System.currentTimeMillis(),
    ): QuotaDisplay {
        if (window == null) {
            return QuotaDisplay(fallbackLabel, remaining = null, expired = false, missing = true)
        }
        val expired = isExpired(window, now)
        val remaining = window.remainingPercentage
            .takeIf { it.isFinite() && !expired }
            ?.roundToInt()
            ?.coerceIn(0, 100)
        return QuotaDisplay(
            label = window.label.ifBlank { fallbackLabel },
            remaining = remaining,
            expired = expired,
            missing = false,
        )
    }

    fun quotaResetText(
        window: UsageWindow?,
        now: Long = System.currentTimeMillis(),
        zoneId: ZoneId = ZoneId.systemDefault(),
    ): String = when {
        window == null -> "暂无额度数据"
        isExpired(window, now) -> "已重置 · 等待更新"
        else -> resetText(window.resetsAt, now, zoneId)
    }

    fun pointsForRange(
        points: List<DailyUsagePoint>,
        range: UsageRange,
    ): List<DailyUsagePoint> = points.takeLast(range.days)

    fun totalTokens(points: List<DailyUsagePoint>): Long =
        points.sumOf { it.totalTokens }

    fun totalEstimatedCostUSD(points: List<DailyUsagePoint>): Double? {
        val costs = points.mapNotNull { it.estimatedCostUSD }
        return costs.takeIf { it.isNotEmpty() }?.sum()
    }

    fun compactTokens(value: Long): String = when {
        value >= 1_000_000_000 -> decimal(value / 1_000_000_000.0) + "B"
        value >= 1_000_000 -> decimal(value / 1_000_000.0) + "M"
        value >= 1_000 -> decimal(value / 1_000.0) + "K"
        else -> value.coerceAtLeast(0).toString()
    }

    fun estimatedCostUSD(value: Double?): String {
        value ?: return "--"
        val safeValue = value.coerceAtLeast(0.0)
        return when {
            safeValue >= 1_000 -> "$" + decimal(safeValue / 1_000) + "K"
            safeValue >= 100 -> String.format(
                java.util.Locale.US,
                "$%.0f",
                safeValue,
            )
            safeValue >= 10 -> String.format(
                java.util.Locale.US,
                "$%.1f",
                safeValue,
            )
            else -> String.format(
                java.util.Locale.US,
                "$%.2f",
                safeValue,
            )
        }
    }

    fun resetText(
        resetsAt: Long?,
        now: Long = System.currentTimeMillis(),
        zoneId: ZoneId = ZoneId.systemDefault(),
    ): String {
        resetsAt ?: return "重置时间未知"
        val remaining = resetsAt - now
        if (remaining <= 0) return "即将重置"

        val minutes = ceil(remaining / 60_000.0).toLong().coerceAtLeast(1)
        if (minutes < 60) return "${minutes} 分后重置"

        val hours = minutes / 60
        val restMinutes = minutes % 60
        if (hours < 24) {
            return if (restMinutes == 0L) {
                "${hours} 小时后重置"
            } else {
                "${hours} 小时 ${restMinutes} 分后重置"
            }
        }

        val formatter = DateTimeFormatter.ofPattern("MM月dd日 HH:mm")
        return formatter.format(
            Instant.ofEpochMilli(resetsAt).atZone(zoneId),
        ) + " 重置"
    }

    fun freshnessText(
        capturedAt: Long?,
        now: Long = System.currentTimeMillis(),
    ): String {
        capturedAt ?: return "等待用量数据"
        val elapsedMinutes = ((now - capturedAt).coerceAtLeast(0) / 60_000)
        return when {
            elapsedMinutes < 1 -> "刚刚更新"
            elapsedMinutes < 60 -> "${elapsedMinutes} 分钟前更新"
            elapsedMinutes < 24 * 60 -> "${elapsedMinutes / 60} 小时前更新"
            else -> "${elapsedMinutes / (24 * 60)} 天前更新"
        }
    }

    fun dateLabel(date: String): String {
        val parts = date.split("-")
        if (parts.size != 3) return date
        return "${parts[1]}/${parts[2]}"
    }

    private fun decimal(value: Double): String {
        val rounded = kotlin.math.round(value * 10) / 10
        return if (rounded % 1.0 == 0.0) {
            rounded.toLong().toString()
        } else {
            String.format(java.util.Locale.US, "%.1f", rounded)
        }
    }
}
