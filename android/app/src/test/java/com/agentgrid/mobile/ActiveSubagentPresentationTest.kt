package com.agentgrid.mobile

import com.agentgrid.mobile.domain.*
import com.agentgrid.mobile.render.PixelPalette
import com.agentgrid.mobile.render.PixelRenderState
import com.agentgrid.mobile.ui.taskStatusText
import org.junit.Assert.*
import org.junit.Test

class ActiveSubagentPresentationTest {
    private fun task(lifecycle: AgentLifecycle) = TaskSnapshot(
        "hermes-desktop:session:parent", AgentSource.HERMES_DESKTOP, "Hermes",
        lifecycle = lifecycle, activeSubagents = 2, activity = null,
        startedAt = 1, updatedAt = 2, completedAt = if (lifecycle == AgentLifecycle.SUCCEEDED) 2 else null,
    )

    @Test fun `count only delegation keeps the task view visible instead of treating parent as presence or finished`() {
        for (life in listOf(AgentLifecycle.IDLE, AgentLifecycle.SUCCEEDED)) {
            val parent = task(life)
            val projected = TaskDashboardProjector.project(listOf(parent), null, null, now = 200_000)
            assertFalse(projected.dashboardVisible)
            assertNull(projected.nextDashboardAt)
        }
    }

    @Test fun `parent with count only renders working purple delegation instead of idle or success`() {
        for (life in listOf(AgentLifecycle.IDLE, AgentLifecycle.SUCCEEDED, AgentLifecycle.RUNNING, AgentLifecycle.STARTING)) {
            val parent = task(life)
            val render = PixelRenderState.forTask(parent)
            assertEquals(AgentLifecycle.RUNNING, render.lifecycle)
            assertEquals(AgentActivity.DELEGATING, render.activity)
            assertEquals("子代理工作中 · 2 个", taskStatusText(parent))
            assertEquals(0xFFA78BFA.toInt(), PixelPalette.color(render.lifecycle, render.activity))
        }
    }

    @Test fun `delegation never hides pending attention or offline and interrupted states`() {
        for (life in listOf(AgentLifecycle.WAITING_APPROVAL, AgentLifecycle.WAITING_ANSWER, AgentLifecycle.OFFLINE, AgentLifecycle.INTERRUPTED)) {
            val parent = task(life)
            assertEquals(life, PixelRenderState.forTask(parent).lifecycle)
            assertFalse(taskStatusText(parent).contains("子代理工作中"))
        }
        val idle = task(AgentLifecycle.IDLE).copy(activeSubagents = 0)
        assertEquals(AgentLifecycle.IDLE, PixelRenderState.forTask(idle).lifecycle)
    }
}
