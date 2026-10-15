package com.agentgrid.mobile

import com.agentgrid.mobile.domain.AgentLifecycle
import com.agentgrid.mobile.domain.AgentActivity
import com.agentgrid.mobile.domain.AgentSource
import com.agentgrid.mobile.domain.TaskSnapshot
import com.agentgrid.mobile.ui.shouldShowTokenSummary
import com.agentgrid.mobile.ui.taskStatusText
import com.agentgrid.mobile.ui.lifecycleStatusText
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TaskRowSummaryTest {
    @Test
    fun `已中断任务保留用户输入`() {
        val task = task(AgentLifecycle.INTERRUPTED)

        assertFalse(shouldShowTokenSummary(task))
    }

    @Test
    fun `成功任务显示 Token 摘要`() {
        val task = task(AgentLifecycle.SUCCEEDED)

        assertTrue(shouldShowTokenSummary(task))
    }

    @Test
    fun `启动和思考在手机文案上明确区分`() {
        val starting = task(AgentLifecycle.STARTING)
        val thinking = task(AgentLifecycle.RUNNING).copy(activity = AgentActivity.THINKING)

        org.junit.Assert.assertEquals("正在启动", taskStatusText(starting))
        org.junit.Assert.assertEquals("正在思考", taskStatusText(thinking))
        org.junit.Assert.assertEquals("正在运行", lifecycleStatusText(AgentLifecycle.RUNNING))
    }

    private fun task(lifecycle: AgentLifecycle) = TaskSnapshot(
        id = "task-1",
        source = AgentSource.CODEX_CLI,
        projectName = "AgentGrid",
        userPrompt = "保留这条用户输入",
        lifecycle = lifecycle,
        startedAt = 1_000,
        updatedAt = 2_000,
        completedAt = 2_000,
    )
}
