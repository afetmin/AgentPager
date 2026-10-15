package com.agentgrid.mobile.ui

import com.agentgrid.mobile.domain.AgentActivity
import com.agentgrid.mobile.domain.AgentLifecycle
import com.agentgrid.mobile.domain.TaskSnapshot

internal fun shouldShowTokenSummary(task: TaskSnapshot): Boolean =
    task.lifecycle == AgentLifecycle.SUCCEEDED

internal fun taskStatusText(task: TaskSnapshot): String =
    if (task.lifecycle == AgentLifecycle.RUNNING) {
        activityStatusText(task.activity)
    } else {
        lifecycleStatusText(task.lifecycle)
    }

internal fun lifecycleStatusText(lifecycle: AgentLifecycle): String = when (lifecycle) {
    AgentLifecycle.OFFLINE -> "离线"
    AgentLifecycle.IDLE -> "空闲"
    AgentLifecycle.STARTING -> "正在启动"
    AgentLifecycle.RUNNING -> "正在运行"
    AgentLifecycle.WAITING_APPROVAL -> "等待批准"
    AgentLifecycle.WAITING_ANSWER -> "等待回答"
    AgentLifecycle.SUCCEEDED -> "任务完成"
    AgentLifecycle.INTERRUPTED -> "已中断"
}

internal fun activityStatusText(activity: AgentActivity?): String = when (activity) {
    AgentActivity.THINKING -> "正在思考"
    AgentActivity.READING -> "正在读取"
    AgentActivity.SEARCHING -> "正在搜索"
    AgentActivity.EDITING -> "正在编辑"
    AgentActivity.EXECUTING -> "正在执行"
    AgentActivity.TESTING -> "正在测试"
    AgentActivity.BROWSING -> "正在浏览"
    AgentActivity.DELEGATING -> "正在协作"
    null -> "正在运行"
}
