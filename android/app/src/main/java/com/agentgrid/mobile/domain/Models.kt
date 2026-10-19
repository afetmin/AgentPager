package com.agentgrid.mobile.domain

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
enum class AgentSource {
    @SerialName("codexDesktop")
    CODEX_DESKTOP,

    @SerialName("codexCLI")
    CODEX_CLI,

    @SerialName("claudeCode")
    CLAUDE_CODE,
}

@Serializable
enum class AgentLifecycle {
    @SerialName("offline")
    OFFLINE,

    @SerialName("idle")
    IDLE,

    @SerialName("starting")
    STARTING,

    @SerialName("running")
    RUNNING,

    @SerialName("waitingApproval")
    WAITING_APPROVAL,

    @SerialName("waitingAnswer")
    WAITING_ANSWER,

    @SerialName("succeeded")
    SUCCEEDED,

    @SerialName("interrupted")
    INTERRUPTED,
}

@Serializable
enum class AgentActivity {
    @SerialName("thinking")
    THINKING,

    @SerialName("reading")
    READING,

    @SerialName("searching")
    SEARCHING,

    @SerialName("editing")
    EDITING,

    @SerialName("executing")
    EXECUTING,

    @SerialName("testing")
    TESTING,

    @SerialName("browsing")
    BROWSING,

    @SerialName("delegating")
    DELEGATING,
}

@Serializable
enum class TaskCapability {
    @SerialName("approve")
    APPROVE,

    @SerialName("deny")
    DENY,

    @SerialName("answer")
    ANSWER,

    @SerialName("interrupt")
    INTERRUPT,

    @SerialName("retry")
    RETRY,
}

@Serializable
data class TokenUsage(
    val input: Int = 0,
    val cachedInput: Int = 0,
    val output: Int = 0,
    val reasoningOutput: Int = 0,
    val total: Int = 0,
)

@Serializable
data class SubagentSnapshot(
    val id: String,
    val path: String,
    val displayName: String,
    val lifecycle: AgentLifecycle = AgentLifecycle.RUNNING,
    val activity: AgentActivity? = AgentActivity.THINKING,
    val latestStep: String? = null,
    val tokenUsage: TokenUsage? = null,
    val startedAt: Long,
    val updatedAt: Long,
) {
    val isTerminal: Boolean
        get() = lifecycle in setOf(
            AgentLifecycle.SUCCEEDED,
            AgentLifecycle.INTERRUPTED,
        )

    fun elapsedAt(now: Long): Long =
        ((if (isTerminal) updatedAt else now) - startedAt).coerceAtLeast(0)
}

@Serializable
data class TaskSnapshot(
    val id: String,
    val source: AgentSource,
    val projectName: String,
    val title: String = projectName,
    val userPrompt: String? = null,
    val latestStep: String? = null,
    val tokenUsage: TokenUsage? = null,
    val subagents: List<SubagentSnapshot> = emptyList(),
    val lifecycle: AgentLifecycle,
    val activity: AgentActivity? = null,
    val startedAt: Long,
    val updatedAt: Long,
    val completedAt: Long? = null,
    val isUnread: Boolean = false,
    val isPinned: Boolean = false,
    val isMuted: Boolean = false,
    val capabilities: Set<TaskCapability> = emptySet(),
    // 兼容 Claude Code 协议的其他客户端（如 ZCode、WorkBuddy）的展示名；source 仍是 claudeCode。
    // 旧版 Mac 端不发送该字段，因此必须可空且有默认值。
    val agentName: String? = null,
) {
    val isTerminal: Boolean
        get() = lifecycle in setOf(
            AgentLifecycle.SUCCEEDED,
            AgentLifecycle.INTERRUPTED,
        )

    fun elapsedAt(now: Long): Long {
        val endAt = if (isTerminal) {
            requireNotNull(completedAt) { "终态任务必须包含完成时间" }
        } else {
            now
        }
        return (endAt - startedAt).coerceAtLeast(0)
    }

    val attentionPriority: Int
        get() {
            val lifecycleValue = when (lifecycle) {
                AgentLifecycle.WAITING_APPROVAL -> 600
                AgentLifecycle.WAITING_ANSWER -> 500
                AgentLifecycle.SUCCEEDED -> 300
                AgentLifecycle.STARTING, AgentLifecycle.RUNNING -> 200
                else -> 100
            }
            val unreadValue = if (isUnread && lifecycle == AgentLifecycle.SUCCEEDED) 50 else 0
            val pinnedValue = if (isPinned) 25 else 0
            return lifecycleValue + unreadValue + pinnedValue
        }
}

@Serializable
data class UsageWindow(
    val key: String,
    val label: String,
    val usedPercentage: Double,
    val remainingPercentage: Double,
    val windowMinutes: Int,
    val resetsAt: Long? = null,
)

@Serializable
data class DailyUsagePoint(
    val date: String,
    val inputTokens: Long = 0,
    val cachedInputTokens: Long = 0,
    val outputTokens: Long = 0,
    val reasoningOutputTokens: Long = 0,
    val totalTokens: Long = 0,
    val estimatedCostUSD: Double? = null,
)

@Serializable
data class UsageSnapshot(
    val capturedAt: Long? = null,
    val planType: String? = null,
    val limitID: String? = null,
    val windows: List<UsageWindow> = emptyList(),
    val dailyUsage: List<DailyUsagePoint> = emptyList(),
)

@Serializable
data class StateSnapshotPayload(
    val tasks: List<TaskSnapshot>,
    val usage: UsageSnapshot? = null,
    val focusedTaskID: String? = null,
    val pendingRequests: List<PendingRequest> = emptyList(),
)

@Serializable
enum class PendingRequestKind {
    @SerialName("approval")
    APPROVAL,

    @SerialName("question")
    QUESTION,
}

@Serializable
data class PendingRequest(
    val taskID: String,
    val kind: PendingRequestKind,
    val summary: String? = null,
    val options: List<String> = emptyList(),
)

@Serializable
data class StateEnvelope(
    val version: Int,
    val messageId: String,
    val type: String,
    val sentAt: Long,
    val payload: StateSnapshotPayload,
)

@Serializable
enum class ControlResult {
    @SerialName("accepted")
    ACCEPTED,

    @SerialName("rejected")
    REJECTED,

    @SerialName("stale")
    STALE,

    @SerialName("unsupported")
    UNSUPPORTED,
}

@Serializable
data class ControlAckPayload(
    val requestID: String,
    val result: ControlResult,
    val reason: String? = null,
)

@Serializable
enum class ControlAction {
    @SerialName("approve")
    APPROVE,

    @SerialName("deny")
    DENY,

    @SerialName("answer")
    ANSWER,

    @SerialName("interrupt")
    INTERRUPT,

    @SerialName("retry")
    RETRY,

    @SerialName("mute")
    MUTE,

    @SerialName("markRead")
    MARK_READ,

    @SerialName("pin")
    PIN,
}

@Serializable
data class ControlPayload(
    val taskID: String,
    val action: ControlAction,
    val value: String? = null,
)

@Serializable
data class SignedControlEnvelope(
    val version: Int = 1,
    val messageId: String,
    val type: String = "control.request",
    val sentAt: Long,
    val deviceId: String,
    val sequence: ULong,
    val nonce: String,
    val payload: ControlPayload,
    val signature: String,
)

@Serializable
data class PairingPayload(
    val version: Int,
    val serviceID: String,
    val host: String,
    val port: Int,
    val secret: String,
)
