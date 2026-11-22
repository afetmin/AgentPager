package com.agentgrid.mobile.ui

import com.agentgrid.mobile.domain.*
import org.junit.Assert.*
import org.junit.Test

class HermesUsagePresentationTest {
    private fun task(usage: SessionModelUsage? = null, lifecycle: AgentLifecycle = AgentLifecycle.RUNNING) = TaskSnapshot(
        id = "hermes", source = AgentSource.HERMES_DESKTOP, projectName = "Hermes", lifecycle = lifecycle,
        startedAt = 1000, updatedAt = 2000, modelUsage = usage,
    )
    @Test fun `summary separates native tokens from explicit USD estimate`() {
        val usage = SessionModelUsage(1000, 200, 1200, model = "model-a", estimatedCostUSD = 0.25, costSource = "current_model_pricing")
        assertEquals("model-a · 1.2K TOK · 预估 \$0.25", HermesUsagePresentation.summary(task(usage)))
        assertEquals("模型用量暂不可用", HermesUsagePresentation.summary(task()))
        assertTrue(HermesUsagePresentation.costDetails(usage).contains("不代表账单"))
        assertEquals("model-a · 1.2K TOK · 预估 <\$0.01", HermesUsagePresentation.summary(task(usage.copy(estimatedCostUSD = 0.001))))
        assertFalse(HermesUsagePresentation.summary(task(usage.copy(estimatedCostUSD = null))).contains("\$0"))
    }
    @Test fun `quota suppresses expired offline malformed and unknown-source gauges`() {
        val quota = SessionQuota("Today", 12.5, "session_plan_gauge", 5000)
        val usage = SessionModelUsage(10, 2, 12, quota = quota)
        assertTrue(HermesUsagePresentation.quotaText(task(usage), 3000)!!.contains("已用 12.5%"))
        assertNull(HermesUsagePresentation.quotaText(task(usage), 5000))
        assertNull(HermesUsagePresentation.quotaText(task(usage, AgentLifecycle.OFFLINE), 3000))
        assertNull(HermesUsagePresentation.quotaText(task(usage.copy(quota = quota.copy(usedPercentage = Double.NaN))), 3000))
        assertNull(HermesUsagePresentation.quotaText(task(usage.copy(quota = quota.copy(source = "context_window"))), 3000))
    }
}
