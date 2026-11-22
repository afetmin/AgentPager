package com.agentgrid.mobile.ui

import com.agentgrid.mobile.domain.AgentLifecycle
import com.agentgrid.mobile.domain.AgentSource
import com.agentgrid.mobile.domain.SessionModelUsage
import com.agentgrid.mobile.domain.TaskSnapshot
import java.util.Locale

internal data class HermesDashboardPresentation(
    val sessions: List<HermesSessionPresentation>,
    val emptyMessage: String?,
)

internal data class HermesSessionPresentation(
    val id: String,
    val title: String,
    val status: String,
    val model: String,
    val tokens: String,
    val cost: String,
    val quota: String?,
)

internal object HermesUsagePresentation {
    fun dashboard(tasks: List<TaskSnapshot>, connected: Boolean, now: Long): HermesDashboardPresentation {
        val rows = sessions(tasks).map { task ->
            val usage = task.modelUsage
            fun tokens(value: Int?): String = value?.takeIf { it >= 0 }
                ?.let { UsagePresentation.compactTokens(it.toLong()) } ?: "未知"
            HermesSessionPresentation(
                id = task.id,
                title = task.title,
                status = when {
                    !connected -> "Bridge 离线 · 缓存快照"
                    task.lifecycle == AgentLifecycle.OFFLINE -> "离线 · 最后快照"
                    else -> lifecycleStatusText(task.lifecycle)
                },
                model = listOfNotNull(usage?.provider?.takeIf { it.isNotBlank() }, usage?.model?.takeIf { it.isNotBlank() })
                    .joinToString(" · ").ifEmpty { "模型未知" },
                tokens = "IN ${tokens(usage?.inputTokens)} · OUT ${tokens(usage?.outputTokens)} · TOTAL ${tokens(usage?.totalTokens)} TOK",
                cost = usage?.let(::costDetails) ?: "USD 估算不可用（未上报模型用量）",
                quota = if (connected) quotaText(task, now) else null,
            )
        }
        return HermesDashboardPresentation(
            sessions = rows,
            emptyMessage = when {
                rows.isNotEmpty() -> null
                !connected -> "Bridge 离线 · 暂无 Hermes 会话快照"
                tasks.filter { it.source == AgentSource.HERMES_DESKTOP && it.id == "hermes-desktop:status" }
                    .maxByOrNull { it.updatedAt }?.lifecycle == AgentLifecycle.OFFLINE ->
                    "Hermes Desktop 离线 · 暂无会话快照"
                else -> "暂无 Hermes 会话用量 · 等待桌面端会话快照"
            },
        )
    }

    /** Snapshots are cumulative per session, never daily usage or additional subagent counters. */
    fun sessions(tasks: List<TaskSnapshot>): List<TaskSnapshot> = tasks
        .filter { it.source == AgentSource.HERMES_DESKTOP && it.id != "hermes-desktop:status" }
        .groupBy { it.id }
        .values
        .map { duplicates -> duplicates.withIndex().maxWith(
            compareBy<IndexedValue<TaskSnapshot>> { it.value.updatedAt }.thenBy { it.index },
        ).value }
        .sortedWith(compareByDescending<TaskSnapshot> { it.updatedAt }.thenBy { it.id })

    private fun usd(value: Double): String = if (value > 0 && value < 0.01) "<\$0.01" else UsagePresentation.estimatedCostUSD(value)

    fun summary(task: TaskSnapshot): String {
        val usage = task.modelUsage ?: return "模型用量暂不可用"
        val tokens = usage.totalTokens.takeIf { it >= 0 }?.let { UsagePresentation.compactTokens(it.toLong()) + " TOK" }
            ?: "TOKEN 未知"
        val cost = usage.estimatedCostUSD?.takeIf { it.isFinite() && it >= 0 }
            ?.let { " · 预估 " + usd(it) }.orEmpty()
        return (usage.model?.takeIf { it.isNotBlank() } ?: "模型未知") + " · " + tokens + cost
    }

    fun costDetails(usage: SessionModelUsage): String {
        val cost = usage.estimatedCostUSD?.takeIf { it.isFinite() && it >= 0 } ?: return "USD 估算不可用（无原生费用或匹配价格）"
        val basis = if (usage.costSource == "sdk_reported") "SDK 报告值，未声明实付性质" else
            "按当前模型标价粗估，未区分缓存折扣及历史模型"
        return "预估 ${usd(cost)} USD · $basis；不代表账单或订阅扣款"
    }

    fun quotaText(task: TaskSnapshot, now: Long = System.currentTimeMillis()): String? {
        if (task.lifecycle == AgentLifecycle.OFFLINE) return null
        val quota = task.modelUsage?.quota ?: return null
        if (quota.source !in setOf("session_plan_gauge", "provider_cache") ||
            !quota.usedPercentage.isFinite() || quota.usedPercentage !in 0.0..100.0 ||
            quota.resetsAt?.let { it <= now } == true) return null
        val percent = String.format(Locale.US, "%.1f", quota.usedPercentage)
        val basis = if (quota.source == "provider_cache") "提供商缓存" else "会话原生额度"
        return "$basis · ${quota.label} · 已用 $percent% · " + UsagePresentation.resetText(quota.resetsAt, now)
    }
}
