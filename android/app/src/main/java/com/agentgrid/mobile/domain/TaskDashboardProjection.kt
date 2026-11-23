package com.agentgrid.mobile.domain

data class TaskDashboardProjection(
    val orderedTasks: List<TaskSnapshot>,
    val focusedTaskID: String?,
    val visibleTaskIDs: List<String>,
    val enteringVisibleTaskIDs: Set<String>,
    val urgentTaskID: String?,
    val automaticallyExpandedTaskID: String?,
    val dashboardVisible: Boolean,
    val manualDashboardOverride: Boolean?,
    val nextDashboardAt: Long?,
    internal val terminalStates: Map<String, Boolean>,
) {
    val focusedTask: TaskSnapshot?
        get() = orderedTasks.firstOrNull { it.id == focusedTaskID }

    val visibleTasks: List<TaskSnapshot>
        get() {
            val visibleIDs = visibleTaskIDs.toSet()
            return orderedTasks.filter { it.id in visibleIDs }
        }

    fun focusing(taskID: String): TaskDashboardProjection =
        if (orderedTasks.any { it.id == taskID }) {
            copy(focusedTaskID = taskID)
        } else {
            this
        }

    fun togglingDashboard(): TaskDashboardProjection {
        val visible = !dashboardVisible
        return copy(
            dashboardVisible = visible,
            manualDashboardOverride = visible,
        )
    }

    companion object {
        fun empty(): TaskDashboardProjection = TaskDashboardProjection(
            orderedTasks = emptyList(),
            focusedTaskID = null,
            visibleTaskIDs = emptyList(),
            enteringVisibleTaskIDs = emptySet(),
            urgentTaskID = null,
            automaticallyExpandedTaskID = null,
            dashboardVisible = true,
            manualDashboardOverride = null,
            nextDashboardAt = null,
            terminalStates = emptyMap(),
        )
    }
}

object TaskDashboardProjector {
    const val IDLE_DELAY_MILLIS = 90_000L
    const val VISIBLE_TASK_LIMIT = 5

    fun project(
        snapshot: StateSnapshotPayload,
        previous: TaskDashboardProjection?,
        now: Long,
    ): TaskDashboardProjection = project(
        tasks = snapshot.tasks,
        preferredFocusedTaskID = snapshot.focusedTaskID,
        previous = previous,
        now = now,
    )

    fun project(
        tasks: List<TaskSnapshot>,
        preferredFocusedTaskID: String?,
        previous: TaskDashboardProjection?,
        manualDashboardOverride: Boolean? = previous?.manualDashboardOverride,
        now: Long,
        idleDelayMillis: Long = IDLE_DELAY_MILLIS,
        visibleLimit: Int = VISIBLE_TASK_LIMIT,
    ): TaskDashboardProjection {
        require(idleDelayMillis >= 0) { "任务结束等待时间不能为负数" }
        require(visibleLimit > 0) { "可见任务数量必须大于零" }

        val orderedTasks = normalize(tasks).sortedWith(taskComparator)
        val visibleTaskIDs = orderedTasks
            .take(visibleLimit)
            .map { it.id }
        val enteringVisibleTaskIDs = if (previous?.visibleTaskIDs.isNullOrEmpty()) {
            emptySet()
        } else {
            visibleTaskIDs
                .filterNotTo(linkedSetOf()) { it in previous.visibleTaskIDs }
        }
        val terminalStates = orderedTasks.associate { it.id to it.isTerminal }
        val hasNewTask = previous != null && orderedTasks.any { task ->
            val wasTerminal = previous.terminalStates[task.id]
            wasTerminal == null || (wasTerminal && !task.isTerminal)
        }
        val effectiveManualOverride = if (hasNewTask) {
            null
        } else {
            manualDashboardOverride
        }
        val nextDashboardAt = nextDashboardAt(
            tasks = orderedTasks,
            now = now,
            idleDelayMillis = idleDelayMillis,
        )
        val automaticDashboardVisible =
            nextDashboardAt == null && orderedTasks.none { !it.isTerminal }
        val focusedTaskID = preferredFocusedTaskID
            ?.takeIf { preferred -> orderedTasks.any { it.id == preferred } }
            ?: previous?.focusedTaskID
                ?.takeIf { previousID -> orderedTasks.any { it.id == previousID } }
            ?: orderedTasks.maxWithOrNull(focusComparator)?.id
        val urgentTaskID = orderedTasks.firstOrNull {
            it.lifecycle == AgentLifecycle.WAITING_APPROVAL ||
                it.lifecycle == AgentLifecycle.WAITING_ANSWER
        }?.id
        val automaticallyExpandedTaskID = urgentTaskID ?: orderedTasks.firstOrNull { task ->
            task.subagents.any { !it.isTerminal }
        }?.id

        return TaskDashboardProjection(
            orderedTasks = orderedTasks,
            focusedTaskID = focusedTaskID,
            visibleTaskIDs = visibleTaskIDs,
            enteringVisibleTaskIDs = enteringVisibleTaskIDs,
            urgentTaskID = urgentTaskID,
            automaticallyExpandedTaskID = automaticallyExpandedTaskID,
            dashboardVisible = effectiveManualOverride ?: automaticDashboardVisible,
            manualDashboardOverride = effectiveManualOverride,
            nextDashboardAt = nextDashboardAt,
            terminalStates = terminalStates,
        )
    }

    private fun normalize(tasks: List<TaskSnapshot>): List<TaskSnapshot> =
        tasks.withIndex()
            .groupBy { it.value.id }
            .values
            .map { duplicates ->
                duplicates.maxWith(
                    compareBy<IndexedValue<TaskSnapshot>> { it.value.updatedAt }
                        .thenBy { it.index },
                ).value
            }

    private fun nextDashboardAt(
        tasks: List<TaskSnapshot>,
        now: Long,
        idleDelayMillis: Long,
    ): Long? {
        if (tasks.any { !it.isTerminal }) return null
        val lastFinishedAt = tasks.maxOfOrNull {
            it.completedAt ?: it.updatedAt
        } ?: return null
        val transitionAt = lastFinishedAt + idleDelayMillis
        return transitionAt.takeIf { it > now }
    }

    private val taskComparator =
        compareByDescending<TaskSnapshot> { it.sortGroup }
            .thenByDescending { it.listPriority }
            .thenByDescending { it.updatedAt }
            .thenBy { it.id }

    private val focusComparator =
        compareBy<TaskSnapshot> { it.attentionPriority }
            .thenBy { it.updatedAt }
            .thenByDescending { it.id }

    private val TaskSnapshot.listPriority: Int
        get() = when (lifecycle) {
            // 已读状态只控制提醒，不应让展开操作改变 Task 位置。
            AgentLifecycle.SUCCEEDED -> if (isPinned) 1 else 0
            else -> attentionPriority
        }

    private val TaskSnapshot.sortGroup: Int
        get() = when (lifecycle) {
            // 等待回答与等待批准一样需要人工介入，不能沉到运行中任务下面被挤出可见范围。
            AgentLifecycle.WAITING_APPROVAL, AgentLifecycle.WAITING_ANSWER -> 3
            AgentLifecycle.RUNNING -> 2
            AgentLifecycle.SUCCEEDED -> 0
            else -> 1
        }
}
