package com.agentgrid.mobile

import com.agentgrid.mobile.domain.AgentLifecycle
import com.agentgrid.mobile.domain.AgentSource
import com.agentgrid.mobile.domain.TaskSnapshot
import com.agentgrid.mobile.ui.agentBadge
import com.agentgrid.mobile.ui.agentOriginLabel
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class TaskSnapshotTest {
    @Test
    fun `运行中的任务使用当前时间计算耗时`() {
        val task = task(AgentLifecycle.RUNNING, updatedAt = 2_000)

        assertEquals(4_000, task.elapsedAt(now = 5_000))
    }

    @Test
    fun `完成的任务使用完成时间冻结耗时`() {
        val task = task(
            lifecycle = AgentLifecycle.SUCCEEDED,
            updatedAt = 3_000,
            completedAt = 2_500,
        )

        assertEquals(1_500, task.elapsedAt(now = 9_000))
    }

    @Test
    fun `旧版 Mac 端不发送 agentName 时仍能解码且展示 Claude`() {
        val task = decode(
            """{"id":"t","source":"claudeCode","projectName":"p","lifecycle":"running","startedAt":1,"updatedAt":2}""",
        )

        assertNull(task.agentName)
        assertEquals("Claude", agentBadge(task))
        assertEquals("Claude Code", agentOriginLabel(task))
    }

    @Test
    fun `兼容客户端使用 agentName 作为徽章而 source 仍是 claudeCode`() {
        val task = decode(
            """{"id":"t","source":"claudeCode","agentName":"ZCode","projectName":"p","lifecycle":"running","startedAt":1,"updatedAt":2}""",
        )

        assertEquals(AgentSource.CLAUDE_CODE, task.source)
        assertEquals("ZCode", agentBadge(task))
        assertEquals("Hook", agentOriginLabel(task))
    }

    private fun decode(text: String): TaskSnapshot =
        Json { ignoreUnknownKeys = true }.decodeFromString(text)

    private fun task(
        lifecycle: AgentLifecycle,
        updatedAt: Long,
        completedAt: Long? = null,
    ) = TaskSnapshot(
        id = "task-1",
        source = AgentSource.CODEX_CLI,
        projectName = "AgentGrid",
        lifecycle = lifecycle,
        startedAt = 1_000,
        updatedAt = updatedAt,
        completedAt = completedAt,
    )
}
