package com.agentgrid.mobile

import android.app.Application
import android.provider.Settings
import androidx.core.content.edit
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.agentgrid.mobile.domain.ControlAction
import com.agentgrid.mobile.domain.PendingRequest
import com.agentgrid.mobile.domain.StateSnapshotPayload
import com.agentgrid.mobile.domain.TaskDashboardProjection
import com.agentgrid.mobile.domain.TaskDashboardProjector
import com.agentgrid.mobile.domain.TaskSnapshot
import com.agentgrid.mobile.domain.UsageSnapshot
import com.agentgrid.mobile.network.LinkState
import com.agentgrid.mobile.network.PairingOutcome
import com.agentgrid.mobile.network.PairingSummary
import com.agentgrid.mobile.network.PhoneSessionFactory
import com.agentgrid.mobile.network.PhoneSessionProblem
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

data class AgentGridUiState(
    val pairing: PairingSummary? = null,
    val linkState: LinkState = LinkState.DISCONNECTED,
    val taskProjection: TaskDashboardProjection = TaskDashboardProjection.empty(),
    val usage: UsageSnapshot? = null,
    val pendingRequests: List<PendingRequest> = emptyList(),
    val pairingError: String? = null,
    val terminalMode: Boolean = true,
) {
    val focusedTask: TaskSnapshot?
        get() = taskProjection.focusedTask
}

class AgentGridViewModel(application: Application) : AndroidViewModel(application) {
    private val preferences =
        application.getSharedPreferences("agentgrid-settings", Application.MODE_PRIVATE)
    private val mutableState = MutableStateFlow(
        AgentGridUiState(
            terminalMode = preferences.getBoolean("terminal-mode", true),
        ),
    )
    val state: StateFlow<AgentGridUiState> = mutableState.asStateFlow()

    private val phoneSession = PhoneSessionFactory.create(
        context = application,
        deviceID = Settings.Secure.getString(
            application.contentResolver,
            Settings.Secure.ANDROID_ID,
        ) ?: "agentgrid-android",
    )
    private var latestSnapshot = StateSnapshotPayload(emptyList())
    private var dashboardTransitionJob: Job? = null

    init {
        viewModelScope.launch {
            phoneSession.state.collect { session ->
                val snapshotChanged = latestSnapshot != session.snapshot
                latestSnapshot = session.snapshot
                val projection = if (snapshotChanged) {
                    TaskDashboardProjector.project(
                        snapshot = session.snapshot,
                        previous = mutableState.value.taskProjection,
                        now = System.currentTimeMillis(),
                    )
                } else {
                    mutableState.value.taskProjection
                }
                mutableState.value = mutableState.value.copy(
                    pairing = session.pairing,
                    linkState = session.link,
                    taskProjection = projection,
                    usage = session.snapshot.usage,
                    pendingRequests = session.snapshot.pendingRequests,
                )
                if (snapshotChanged) scheduleDashboardTransition(projection)
            }
        }
        viewModelScope.launch {
            phoneSession.start()
        }
    }

    fun pair(text: String) {
        viewModelScope.launch {
            when (val outcome = phoneSession.pair(text)) {
                PairingOutcome.Connecting -> {
                    mutableState.value = mutableState.value.copy(pairingError = null)
                }

                is PairingOutcome.Rejected -> {
                    mutableState.value = mutableState.value.copy(
                        pairingError = pairingError(outcome.problem),
                    )
                }
            }
        }
    }

    fun unpair() {
        viewModelScope.launch {
            phoneSession.unpair()
        }
    }

    fun control(taskID: String, action: ControlAction, value: String? = null) {
        viewModelScope.launch {
            phoneSession.control(taskID, action, value)
        }
    }

    fun focus(taskID: String) {
        val projection = mutableState.value.taskProjection.focusing(taskID)
        mutableState.value = mutableState.value.copy(taskProjection = projection)
    }

    fun toggleDashboard() {
        dashboardTransitionJob?.cancel()
        dashboardTransitionJob = null
        val projection = mutableState.value.taskProjection.togglingDashboard()
        mutableState.value = mutableState.value.copy(taskProjection = projection)
    }

    fun setTerminalMode(enabled: Boolean) {
        preferences.edit { putBoolean("terminal-mode", enabled) }
        mutableState.value = mutableState.value.copy(terminalMode = enabled)
    }

    override fun onCleared() {
        dashboardTransitionJob?.cancel()
        phoneSession.close()
    }

    private fun scheduleDashboardTransition(projection: TaskDashboardProjection) {
        dashboardTransitionJob?.cancel()
        dashboardTransitionJob = null
        if (projection.manualDashboardOverride != null) return
        val transitionAt = projection.nextDashboardAt ?: return
        dashboardTransitionJob = viewModelScope.launch {
            delay((transitionAt - System.currentTimeMillis()).coerceAtLeast(0L))
            val refreshed = TaskDashboardProjector.project(
                snapshot = latestSnapshot,
                previous = mutableState.value.taskProjection,
                now = System.currentTimeMillis(),
            )
            mutableState.value = mutableState.value.copy(taskProjection = refreshed)
            scheduleDashboardTransition(refreshed)
        }
    }

    private fun pairingError(problem: PhoneSessionProblem): String = when (problem) {
        PhoneSessionProblem.InvalidPairing -> "二维码内容不是有效的 AgentPager 配对信息"
        PhoneSessionProblem.UnsupportedVersion -> "配对信息版本不受支持"
        PhoneSessionProblem.InvalidEndpoint -> "配对地址或端口无效"
        PhoneSessionProblem.InvalidSecret -> "配对密钥无效"
        PhoneSessionProblem.CredentialFailure -> "无法安全保存配对信息"
        else -> "无法建立 AgentPager 配对"
    }
}
