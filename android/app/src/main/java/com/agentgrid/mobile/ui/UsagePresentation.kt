package com.agentgrid.mobile.ui

import com.agentgrid.mobile.domain.DailyUsagePoint
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import kotlin.math.ceil

internal enum class UsageRange(
    val days: Int,
    val label: String,
) {
    SEVEN_DAYS(7, "7 天"),
    THIRTY_DAYS(30, "30 天"),
    NINETY_DAYS(90, "90 天"),
}

internal object UsagePresentation {
    fun pointsForRange(
        points: List<DailyUsagePoint>,
        range: UsageRange,
    ): List<DailyUsagePoint> = points.takeLast(range.days)

    fun totalTokens(points: List<DailyUsagePoint>): Long =
        points.sumOf { it.totalTokens }

    fun totalEstimatedCostUSD(points: List<DailyUsagePoint>, isPartial: Boolean = false): Double? {
        // A sum from only readable rollouts is not a complete cost estimate.
        if (isPartial) return null
        if (points.any { it.totalTokens > 0 && (it.estimatedCostUSD == null || !it.estimatedCostUSD.isFinite() || it.estimatedCostUSD < 0) }) return null
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
