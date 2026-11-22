package com.agentgrid.mobile.ui

import com.agentgrid.mobile.domain.AgentLifecycle
import com.agentgrid.mobile.domain.DailyUsagePoint
import com.agentgrid.mobile.domain.HermesUsageSnapshot
import com.agentgrid.mobile.domain.ModelTokenTotal
import com.agentgrid.mobile.domain.PendingRequest
import com.agentgrid.mobile.domain.TaskSnapshot
import java.time.LocalDate
import kotlinx.coroutines.delay

internal data class ModelShare(val model: String, val tokens: Long, val share: Float)
internal data class UsageAggregate(val totalTokens: Long, val estimatedCostUSD: Double?)
internal data class HermesHistoryView(val models: List<ModelShare>, val points: List<DailyUsagePoint>, val aggregate: UsageAggregate, val isPartial: Boolean)

internal object HermesHistoryPresentation {
    fun project(history: HermesUsageSnapshot?, range: UsageRange, today: LocalDate = LocalDate.now()): HermesHistoryView {
        val first = today.minusDays(range.days - 1L)
        val dates = (0 until range.days).map { first.plusDays(it.toLong()).toString() }
        val known = history?.dailyUsage.orEmpty().associateBy { it.date }
        // Pad missing calendar dates before sharing Codex's takeLast(n) chart selector.
        val points = dates.map { known[it] ?: DailyUsagePoint(it, estimatedCostUSD = 0.0) }
        val period = history?.periods?.firstOrNull { it.days == range.days }
        val total = (period?.totalTokens ?: points.sumOf { it.totalTokens }).coerceAtLeast(0)
        val rows = period?.models ?: history?.modelUsage.orEmpty().filter { it.date in dates && it.totalTokens >= 0 }
            .map { ModelTokenTotal(it.model, it.totalTokens, it.reasoningEffort) }
        val byModel = rows.filter { it.totalTokens >= 0 }.groupBy { it.model }
        val top = byModel.map { (model, rows) ->
            val tokens = rows.sumOf { it.totalTokens }
            ModelShare(model, tokens, if (total == 0L) 0f else (tokens.toDouble() / total).toFloat().coerceIn(0f,1f))
        }.filter { it.tokens > 0 }.sortedWith(compareByDescending<ModelShare> { it.tokens }.thenBy { it.model }).take(3)
        val partial = history?.isPartial == true || period?.isPartial == true
        val cost = if (partial) null else if (period != null) period.estimatedCostUSD else UsagePresentation.totalEstimatedCostUSD(points)
        return HermesHistoryView(top,points,UsageAggregate(total,cost),partial)
    }
}

internal object IdleDataRotation {
    const val intervalMs = 15_000L
    private val work = setOf(AgentLifecycle.STARTING, AgentLifecycle.RUNNING, AgentLifecycle.WAITING_APPROVAL, AgentLifecycle.WAITING_ANSWER)
    fun visibleTabs(sources: List<String>): List<DataUsageTab> = DataUsageTab.entries.filter { tab ->
        when (tab) {
            DataUsageTab.CODEX -> "codex"
            DataUsageTab.CLAUDE -> "claude"
            DataUsageTab.HERMES -> "hermes"
        } in sources
    }
    fun currentVisible(current: DataUsageTab, tabs: List<DataUsageTab>): DataUsageTab? =
        current.takeIf { it in tabs } ?: tabs.firstOrNull()
    fun allowed(
        connected: Boolean, visible: Boolean, tasks: List<TaskSnapshot>,
        tabs: List<DataUsageTab> = DataUsageTab.entries, pendingRequests: List<PendingRequest> = emptyList(),
    ): Boolean = connected && visible && tabs.size > 1 && pendingRequests.isEmpty() &&
        tasks.none { it.activeSubagents > 0 || it.lifecycle in work || it.subagents.any { sub -> sub.lifecycle in work } }
    fun next(current: DataUsageTab, tabs: List<DataUsageTab> = DataUsageTab.entries): DataUsageTab? =
        if (tabs.isEmpty()) null else tabs[(tabs.indexOf(current) + 1) % tabs.size]
    suspend fun advanceAfterDelay(current: DataUsageTab, tabs: List<DataUsageTab> = DataUsageTab.entries, selected: (DataUsageTab) -> Unit) {
        if (tabs.size <= 1) return
        delay(intervalMs)
        next(current, tabs)?.let(selected)
    }
}
