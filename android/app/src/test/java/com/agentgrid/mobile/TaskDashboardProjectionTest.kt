package com.agentgrid.mobile

import com.agentgrid.mobile.domain.AgentLifecycle
import com.agentgrid.mobile.domain.AgentSource
import com.agentgrid.mobile.domain.StateSnapshotPayload
import com.agentgrid.mobile.domain.SubagentSnapshot
import com.agentgrid.mobile.domain.TaskDashboardProjector
import com.agentgrid.mobile.domain.TaskSnapshot
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class TaskDashboardProjectionTest {
    @Test
    fun `排序分组稳定且已读变化不移动完成任务`() {
        val approval = task("approval", AgentLifecycle.WAITING_APPROVAL, 10)
        val running = task("running", AgentLifecycle.RUNNING, 30)
        val starting = task("starting", AgentLifecycle.STARTING, 40)
        val succeededB = task("b", AgentLifecycle.SUCCEEDED, 20, isUnread = true)
        val succeededA = task("a", AgentLifecycle.SUCCEEDED, 20)

        val before = project(
            listOf(succeededB, starting, succeededA, running, approval),
        ).orderedTasks.map { it.id }
        val after = project(
            listOf(succeededB.copy(isUnread = false), starting, succeededA, running, approval),
        ).orderedTasks.map { it.id }

        assertEquals(listOf("approval", "running", "starting", "a", "b"), before)
        assertEquals(before, after)
    }

    @Test
    fun `等待回答与等待批准同组置顶不会被运行中任务挤出`() {
        val running = (1..6).map { task("run$it", AgentLifecycle.RUNNING, 100L + it) }
        val answer = task("answer", AgentLifecycle.WAITING_ANSWER, 1)
        val approval = task("approval", AgentLifecycle.WAITING_APPROVAL, 2)

        val projection = project(running + answer + approval)

        assertEquals(listOf("approval", "answer"), projection.orderedTasks.take(2).map { it.id })
        assertTrue("answer" in projection.visibleTaskIDs)
        assertEquals("approval", projection.urgentTaskID)
    }

    @Test
    fun `重复 ID 保留更新时间较新且同时间保留最后一个`() {
        val old = task("same", AgentLifecycle.RUNNING, 10)
        val newer = task("same", AgentLifecycle.RUNNING, 20)
        val last = newer.copy(title = "最后一个")

        val projection = project(listOf(old, newer, last))

        assertEquals(1, projection.orderedTasks.size)
        assertEquals("最后一个", projection.orderedTasks.single().title)
    }

    @Test
    fun `列表换位不算进入而列表外任务进入前五会标记`() {
        val original = (1..6).map { index ->
            task("task-$index", AgentLifecycle.RUNNING, (100 - index).toLong())
        }
        val first = project(original)
        val reordered = project(
            original.map {
                if (it.id == "task-2") it.copy(updatedAt = 200) else it
            },
            previous = first,
        )
        val entered = project(
            original.map {
                if (it.id == "task-6") it.copy(updatedAt = 300) else it
            },
            previous = first,
        )

        assertTrue(reordered.enteringVisibleTaskIDs.isEmpty())
        assertEquals(setOf("task-6"), entered.enteringVisibleTaskIDs)
    }

    @Test
    fun `远端焦点优先否则保留用户焦点再回退自动焦点`() {
        val running = task("running", AgentLifecycle.RUNNING, 30)
        val approval = task("approval", AgentLifecycle.WAITING_APPROVAL, 10)
        val automatic = project(listOf(running, approval))
        val userFocused = automatic.focusing("running")

        val retained = TaskDashboardProjector.project(
            snapshot = StateSnapshotPayload(listOf(running, approval)),
            previous = userFocused,
            now = NOW,
        )
        val remote = TaskDashboardProjector.project(
            snapshot = StateSnapshotPayload(
                tasks = listOf(running, approval),
                focusedTaskID = "approval",
            ),
            previous = userFocused,
            now = NOW,
        )

        assertEquals("approval", automatic.focusedTaskID)
        assertEquals("running", retained.focusedTaskID)
        assertEquals("approval", remote.focusedTaskID)
    }

    @Test
    fun `审批任务优先自动展开否则展开活跃 Subagent`() {
        val delegated = task("delegated", AgentLifecycle.RUNNING, 30).copy(
            subagents = listOf(
                SubagentSnapshot(
                    id = "subagent",
                    path = "/root/subagent",
                    displayName = "子代理",
                    lifecycle = AgentLifecycle.RUNNING,
                    startedAt = 1,
                    updatedAt = 2,
                ),
            ),
        )
        val approval = task("approval", AgentLifecycle.WAITING_APPROVAL, 10)

        val delegatedOnly = project(listOf(delegated))
        val urgent = project(listOf(delegated, approval))

        assertEquals("delegated", delegatedOnly.automaticallyExpandedTaskID)
        assertNull(delegatedOnly.urgentTaskID)
        assertEquals("approval", urgent.automaticallyExpandedTaskID)
        assertEquals("approval", urgent.urgentTaskID)
    }

    @Test
    fun `空列表立即显示 Dashboard 活跃任务始终显示任务态`() {
        assertTrue(project(emptyList()).dashboardVisible)
        assertFalse(
            project(listOf(task("running", AgentLifecycle.RUNNING, NOW))).dashboardVisible,
        )
    }

    @Test
    fun `全部终态只返回一次九十秒绝对切换时间`() {
        val completedAt = NOW - 30_000
        val completed = task(
            "done",
            AgentLifecycle.SUCCEEDED,
            completedAt,
            completedAt = completedAt,
        )

        val waiting = project(listOf(completed))
        val expired = TaskDashboardProjector.project(
            tasks = listOf(completed),
            preferredFocusedTaskID = null,
            previous = waiting,
            now = NOW + 60_000,
        )

        assertFalse(waiting.dashboardVisible)
        assertEquals(NOW + 60_000, waiting.nextDashboardAt)
        assertTrue(expired.dashboardVisible)
        assertNull(expired.nextDashboardAt)
    }

    @Test
    fun `手动覆盖会保留直到新增任务或终态任务复活`() {
        val running = task("existing", AgentLifecycle.RUNNING, 10)
        val hidden = project(listOf(running)).togglingDashboard()
        val ordinaryUpdate = project(listOf(running.copy(updatedAt = 20)), previous = hidden)
        val newTask = project(
            listOf(running.copy(updatedAt = 30), task("new", AgentLifecycle.STARTING, 40)),
            previous = ordinaryUpdate,
        )
        val completed = project(
            listOf(
                task(
                    "existing",
                    AgentLifecycle.SUCCEEDED,
                    50,
                    completedAt = 50,
                ),
            ),
        ).togglingDashboard()
        val restarted = project(
            listOf(task("existing", AgentLifecycle.STARTING, 60)),
            previous = completed,
        )

        assertEquals(true, ordinaryUpdate.manualDashboardOverride)
        assertNull(newTask.manualDashboardOverride)
        assertFalse(newTask.dashboardVisible)
        assertNull(restarted.manualDashboardOverride)
        assertFalse(restarted.dashboardVisible)
    }

    @Test
    fun `终态缺完成时间时使用更新时间且时钟倒退仍确定`() {
        val completed = task("done", AgentLifecycle.INTERRUPTED, NOW + 10_000)

        val projection = project(listOf(completed))

        assertEquals(NOW + 100_000, projection.nextDashboardAt)
        assertFalse(projection.dashboardVisible)
    }

    private fun project(
        tasks: List<TaskSnapshot>,
        previous: com.agentgrid.mobile.domain.TaskDashboardProjection? = null,
    ) = TaskDashboardProjector.project(
        tasks = tasks,
        preferredFocusedTaskID = null,
        previous = previous,
        now = NOW,
    )

    private fun task(
        id: String,
        lifecycle: AgentLifecycle,
        updatedAt: Long,
        completedAt: Long? = null,
        isUnread: Boolean = false,
    ) = TaskSnapshot(
        id = id,
        source = AgentSource.CODEX_CLI,
        projectName = id,
        title = id,
        lifecycle = lifecycle,
        startedAt = 0,
        updatedAt = updatedAt,
        completedAt = completedAt,
        isUnread = isUnread,
    )

    private companion object {
        const val NOW = 1_000_000L
    }
}
