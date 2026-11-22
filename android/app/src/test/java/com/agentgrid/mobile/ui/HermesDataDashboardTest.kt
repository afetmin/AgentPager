package com.agentgrid.mobile.ui

import com.agentgrid.mobile.domain.AgentLifecycle
import com.agentgrid.mobile.domain.AgentSource
import com.agentgrid.mobile.domain.SessionModelUsage
import com.agentgrid.mobile.domain.TaskSnapshot
import org.junit.Assert.*
import org.junit.Test

class HermesDataDashboardTest {
    private fun session(id: String, updatedAt: Long = 2_000, usage: SessionModelUsage? = null) = TaskSnapshot(
        id = id, source = AgentSource.HERMES_DESKTOP, projectName = "Hermes", title = id,
        lifecycle = AgentLifecycle.RUNNING, startedAt = 1_000, updatedAt = updatedAt, modelUsage = usage,
    )

    @Test fun `dashboard shows native counters per session and never adds tokenUsage again`() {
        val task = session("a", usage = SessionModelUsage(100, 20, 120, "model-a", "provider-a", 0.25))
            .copy(tokenUsage = com.agentgrid.mobile.domain.TokenUsage(total = 999))
        val dashboard = HermesUsagePresentation.dashboard(listOf(task), connected = true, now = 3_000)
        val row = dashboard.sessions.single()
        assertEquals("a", row.id)
        assertEquals("provider-a · model-a", row.model)
        assertEquals("IN 100 · OUT 20 · TOTAL 120 TOK", row.tokens)
        assertTrue(row.cost.contains("$0.25"))
        assertTrue(row.cost.contains("不代表账单"))
        assertEquals("正在运行", row.status)
        assertNull(row.quota)
        assertNull(dashboard.emptyMessage)
    }

    @Test fun `offline sessions keep last counters but hide live quota`() {
        val usage = SessionModelUsage(10, 2, 12, quota = com.agentgrid.mobile.domain.SessionQuota("Daily", 25.0, "provider_cache", 10_000))
        val task = session("offline", usage = usage).copy(lifecycle = AgentLifecycle.OFFLINE)
        val offline = HermesUsagePresentation.dashboard(listOf(task), connected = true, now = 3_000).sessions.single()
        assertEquals("离线 · 最后快照", offline.status)
        assertNull(offline.quota)
        assertEquals("IN 10 · OUT 2 · TOTAL 12 TOK", offline.tokens)
        val disconnected = HermesUsagePresentation.dashboard(listOf(task.copy(lifecycle = AgentLifecycle.RUNNING)), false, 3_000).sessions.single()
        assertEquals("Bridge 离线 · 缓存快照", disconnected.status)
        assertNull(disconnected.quota)
    }

    @Test fun `missing and malformed usage is unknown rather than zero dollars or fabricated quota`() {
        val missing = HermesUsagePresentation.dashboard(listOf(session("missing")), true, 3_000).sessions.single()
        assertEquals("模型未知", missing.model)
        assertEquals("IN 未知 · OUT 未知 · TOTAL 未知 TOK", missing.tokens)
        assertTrue(missing.cost.contains("不可用"))
        assertFalse(missing.cost.contains("$0"))
        assertNull(missing.quota)
        val malformed = HermesUsagePresentation.dashboard(listOf(session("bad", usage = SessionModelUsage(-1, 0, -1, estimatedCostUSD = Double.NaN))), true, 3_000).sessions.single()
        assertEquals("IN 未知 · OUT 0 · TOTAL 未知 TOK", malformed.tokens)
        assertTrue(malformed.cost.contains("不可用"))
    }

    @Test fun `desktop presence is not a session and empty state explains missing data`() {
        val presence = session("hermes-desktop:status").copy(lifecycle = AgentLifecycle.IDLE)
        val connected = HermesUsagePresentation.dashboard(listOf(presence), true, 3_000)
        assertTrue(connected.sessions.isEmpty())
        assertTrue(connected.emptyMessage!!.contains("等待桌面端会话快照"))
        val desktopOffline = HermesUsagePresentation.dashboard(listOf(presence.copy(lifecycle = AgentLifecycle.OFFLINE)), true, 3_000)
        assertEquals("Hermes Desktop 离线 · 暂无会话快照", desktopOffline.emptyMessage)
        val offline = HermesUsagePresentation.dashboard(emptyList(), false, 3_000)
        assertTrue(offline.emptyMessage!!.contains("Bridge 离线"))
    }

    @Test fun `valid reported quota remains per session and expires without snapshot replacement`() {
        val usage = SessionModelUsage(10, 2, 12, quota = com.agentgrid.mobile.domain.SessionQuota("Daily", 25.0, "provider_cache", 10_000))
        val task = session("quota", usage = usage)
        assertTrue(HermesUsagePresentation.dashboard(listOf(task), true, 3_000).sessions.single().quota!!.contains("已用 25.0%"))
        assertNull(HermesUsagePresentation.dashboard(listOf(task), true, 10_000).sessions.single().quota)
        assertNull(HermesUsagePresentation.dashboard(listOf(task.copy(modelUsage = usage.copy(quota = usage.quota!!.copy(source = "context_window")))), true, 3_000).sessions.single().quota)
    }

    @Test fun `equal timestamp snapshots use last replacement instead of accumulating counters`() {
        val first = session("same", usage = SessionModelUsage(10, 2, 12))
        val last = first.copy(modelUsage = SessionModelUsage(10, 4, 14))
        assertEquals(listOf(last), HermesUsagePresentation.sessions(listOf(first, last)))
    }

    @Test fun `sessions keep latest snapshot once without mixing Codex Claude or desktop presence`() {
        val first = session("hermes-desktop:session:first", usage = SessionModelUsage(10, 2, 12))
        val latest = first.copy(updatedAt = 3_000, modelUsage = SessionModelUsage(20, 4, 24))
        val second = session("hermes-desktop:session:second")
        val tasks = listOf(
            first, latest, second, session("hermes-desktop:status"),
            first.copy(id = "codex", source = AgentSource.CODEX_CLI),
            first.copy(id = "claude", source = AgentSource.CLAUDE_CODE),
        )
        val result = HermesUsagePresentation.sessions(tasks)
        assertEquals(listOf(latest, second), result)
        assertEquals(24, result.first().modelUsage!!.totalTokens)
        assertNull(result.last().modelUsage)
    }
}
