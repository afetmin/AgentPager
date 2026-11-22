package com.agentgrid.mobile.render

import com.agentgrid.mobile.domain.AgentActivity
import com.agentgrid.mobile.domain.AgentLifecycle

data class PixelRenderState(
    val lifecycle: AgentLifecycle = AgentLifecycle.IDLE,
    val activity: AgentActivity? = null,
    val revision: Long = 0,
    val changedAtNanos: Long = System.nanoTime(),
) {
    companion object {
        fun forTask(task: com.agentgrid.mobile.domain.TaskSnapshot): PixelRenderState = PixelRenderState(
            lifecycle = if (task.hasActiveDelegation) AgentLifecycle.RUNNING else task.lifecycle,
            activity = if (task.hasActiveDelegation) AgentActivity.DELEGATING else task.activity,
            revision = if (task.id == "agentgrid-simulator") task.updatedAt else 0,
        )
    }

    fun requiresMotionRestart(previous: PixelRenderState): Boolean =
        lifecycle != previous.lifecycle ||
            activity != previous.activity ||
            revision != previous.revision
}
