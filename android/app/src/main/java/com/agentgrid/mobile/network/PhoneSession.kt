package com.agentgrid.mobile.network

import com.agentgrid.mobile.domain.ControlAckPayload
import com.agentgrid.mobile.domain.ControlAction
import com.agentgrid.mobile.domain.ControlPayload
import com.agentgrid.mobile.domain.ControlResult
import com.agentgrid.mobile.domain.PairingPayload
import com.agentgrid.mobile.domain.SignedControlEnvelope
import com.agentgrid.mobile.domain.StateSnapshotPayload
import java.util.Base64
import java.util.UUID
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.Serializable
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.decodeFromJsonElement

enum class LinkState {
    DISCONNECTED,
    CONNECTING,
    CONNECTED,
}

data class PairingSummary(
    val serviceID: String,
    val host: String,
    val port: Int,
)

sealed interface PhoneSessionProblem {
    data object InvalidPairing : PhoneSessionProblem
    data object UnsupportedVersion : PhoneSessionProblem
    data object InvalidEndpoint : PhoneSessionProblem
    data object InvalidSecret : PhoneSessionProblem
    data object NotPaired : PhoneSessionProblem
    data object NotConnected : PhoneSessionProblem
    data object CredentialFailure : PhoneSessionProblem
    data object SequenceFailure : PhoneSessionProblem
    data object TransportFailure : PhoneSessionProblem
    data object ProtocolFailure : PhoneSessionProblem
}

sealed interface PairingOutcome {
    data object Connecting : PairingOutcome
    data class Rejected(val problem: PhoneSessionProblem) : PairingOutcome
}

sealed interface ControlSubmission {
    data class Queued(val requestID: String) : ControlSubmission
    data class Rejected(val problem: PhoneSessionProblem) : ControlSubmission
}

sealed interface ControlDelivery {
    data class Pending(val submittedAt: Long) : ControlDelivery
    data class Acknowledged(
        val result: ControlResult,
        val reason: String?,
    ) : ControlDelivery

    data object TimedOut : ControlDelivery
    data object SendFailed : ControlDelivery
}

data class PhoneSessionState(
    val pairing: PairingSummary? = null,
    val link: LinkState = LinkState.DISCONNECTED,
    val snapshot: StateSnapshotPayload = StateSnapshotPayload(emptyList()),
    val controls: Map<String, ControlDelivery> = emptyMap(),
    val problem: PhoneSessionProblem? = null,
)

interface PhoneSession : AutoCloseable {
    val state: StateFlow<PhoneSessionState>

    suspend fun start()

    suspend fun pair(encodedPairing: String): PairingOutcome

    suspend fun control(
        taskID: String,
        action: ControlAction,
        value: String? = null,
    ): ControlSubmission

    suspend fun unpair()
}

internal interface PhoneCredentialStore {
    suspend fun load(): PairingPayload?

    suspend fun save(pairing: PairingPayload)

    suspend fun clear()

    suspend fun reserveNextSequence(): ULong
}

internal data class PhoneEndpoint(
    val host: String,
    val port: Int,
)

internal sealed interface TransportEvent {
    data object Opened : TransportEvent
    data class TextReceived(val text: String) : TransportEvent
    data class Closed(val reason: String?) : TransportEvent
    data class Failed(val reason: String?) : TransportEvent
}

internal interface PhoneSessionTransport : AutoCloseable {
    val events: kotlinx.coroutines.flow.Flow<TransportEvent>

    fun connect(endpoint: PhoneEndpoint)

    fun send(text: String): Boolean

    fun disconnect()
}

internal class DefaultPhoneSession(
    private val credentialStore: PhoneCredentialStore,
    private val transport: PhoneSessionTransport,
    private val deviceID: String,
    private val scope: CoroutineScope,
    private val now: () -> Long = System::currentTimeMillis,
    private val requestID: () -> String = { UUID.randomUUID().toString() },
    private val nonce: () -> String = { UUID.randomUUID().toString() },
    private val wait: suspend (Long) -> Unit = { delay(it) },
    private val acknowledgmentTimeoutMillis: Long = 15_000L,
) : PhoneSession {
    private val json = Json {
        ignoreUnknownKeys = true
        // 新版 Bridge 增加未知枚举值或显式 null 时，回退到默认值而不是丢弃整条快照。
        coerceInputValues = true
        encodeDefaults = true
        explicitNulls = false
    }
    private val mutex = Mutex()
    private val mutableState = MutableStateFlow(PhoneSessionState())
    override val state: StateFlow<PhoneSessionState> = mutableState.asStateFlow()

    private var pairing: PairingPayload? = null
    private var started = false
    private var stopped = false
    private var retryCount = 0
    private var reconnectJob: Job? = null
    private var lastSnapshotSentAt = Long.MIN_VALUE
    private var lastSnapshotMessageID: String? = null
    private val timeoutJobs = mutableMapOf<String, Job>()

    init {
        scope.launch {
            transport.events.collect(::acceptTransportEvent)
        }
    }

    override suspend fun start() {
        mutex.withLock {
            if (started) return
            started = true
            stopped = false
            val restored = runCatching { credentialStore.load() }.getOrElse {
                runCatching { credentialStore.clear() }
                mutableState.value = mutableState.value.copy(
                    problem = PhoneSessionProblem.CredentialFailure,
                )
                return
            }
            if (restored != null && validatePairing(restored) != null) {
                runCatching { credentialStore.clear() }
                mutableState.value = PhoneSessionState(
                    problem = PhoneSessionProblem.CredentialFailure,
                )
                return
            }
            pairing = restored
            if (restored == null) {
                mutableState.value = PhoneSessionState()
            } else {
                mutableState.value = mutableState.value.copy(
                    pairing = restored.summary,
                    problem = null,
                )
                connectLocked(restored)
            }
        }
    }

    override suspend fun pair(encodedPairing: String): PairingOutcome {
        val decoded = runCatching {
            json.decodeFromString<PairingPayload>(encodedPairing.trim())
        }.getOrElse {
            return PairingOutcome.Rejected(PhoneSessionProblem.InvalidPairing)
        }
        validatePairing(decoded)?.let { return PairingOutcome.Rejected(it) }

        return mutex.withLock {
            val saved = runCatching { credentialStore.save(decoded) }.isSuccess
            if (!saved) {
                return@withLock PairingOutcome.Rejected(PhoneSessionProblem.CredentialFailure)
            }
            stopped = false
            started = true
            reconnectJob?.cancel()
            reconnectJob = null
            transport.disconnect()
            pairing = decoded
            retryCount = 0
            mutableState.value = PhoneSessionState(
                pairing = decoded.summary,
                link = LinkState.CONNECTING,
            )
            connectLocked(decoded)
            PairingOutcome.Connecting
        }
    }

    override suspend fun control(
        taskID: String,
        action: ControlAction,
        value: String?,
    ): ControlSubmission = mutex.withLock {
        val currentPairing = pairing
            ?: return@withLock ControlSubmission.Rejected(PhoneSessionProblem.NotPaired)
        if (mutableState.value.link != LinkState.CONNECTED) {
            return@withLock ControlSubmission.Rejected(PhoneSessionProblem.NotConnected)
        }
        val sequence = runCatching { credentialStore.reserveNextSequence() }
            .getOrElse {
                return@withLock ControlSubmission.Rejected(
                    PhoneSessionProblem.SequenceFailure,
                )
            }
        val id = requestID()
        val unsigned = SignedControlEnvelope(
            messageId = id,
            sentAt = now(),
            deviceId = deviceID,
            sequence = sequence,
            nonce = nonce(),
            payload = ControlPayload(taskID, action, value),
            signature = "",
        )
        val secret = runCatching { Base64.getDecoder().decode(currentPairing.secret) }
            .getOrElse {
                return@withLock ControlSubmission.Rejected(PhoneSessionProblem.InvalidSecret)
            }
        val signed = unsigned.copy(signature = ControlSigner.sign(unsigned, secret))
        val encoded = runCatching { json.encodeToString(signed) }
            .getOrElse {
                return@withLock ControlSubmission.Rejected(
                    PhoneSessionProblem.ProtocolFailure,
                )
            }
        updateControl(id, ControlDelivery.Pending(unsigned.sentAt))
        if (!transport.send(encoded)) {
            updateControl(id, ControlDelivery.SendFailed)
            return@withLock ControlSubmission.Rejected(PhoneSessionProblem.TransportFailure)
        }
        timeoutJobs[id] = scope.launch {
            wait(acknowledgmentTimeoutMillis)
            mutex.withLock {
                if (mutableState.value.controls[id] is ControlDelivery.Pending) {
                    updateControl(id, ControlDelivery.TimedOut)
                }
                timeoutJobs.remove(id)
            }
        }
        ControlSubmission.Queued(id)
    }

    override suspend fun unpair() {
        mutex.withLock {
            stopped = true
            reconnectJob?.cancel()
            reconnectJob = null
            timeoutJobs.values.forEach(Job::cancel)
            timeoutJobs.clear()
            transport.disconnect()
            val cleared = runCatching { credentialStore.clear() }.isSuccess
            if (!cleared) {
                stopped = false
                mutableState.value = mutableState.value.copy(
                    link = LinkState.DISCONNECTED,
                    problem = PhoneSessionProblem.CredentialFailure,
                )
                return@withLock
            }
            pairing = null
            retryCount = 0
            lastSnapshotSentAt = Long.MIN_VALUE
            lastSnapshotMessageID = null
            mutableState.value = PhoneSessionState()
        }
    }

    override fun close() {
        stopped = true
        reconnectJob?.cancel()
        timeoutJobs.values.forEach(Job::cancel)
        transport.disconnect()
        transport.close()
        scope.cancel()
    }

    private suspend fun acceptTransportEvent(event: TransportEvent) {
        mutex.withLock {
            when (event) {
                TransportEvent.Opened -> {
                    retryCount = 0
                    // 新连接的第一帧必须被接受：Mac 重启或时钟回拨后 sentAt 可能小于旧连接的最后一帧。
                    lastSnapshotSentAt = Long.MIN_VALUE
                    lastSnapshotMessageID = null
                    reconnectJob?.cancel()
                    reconnectJob = null
                    mutableState.value = mutableState.value.copy(
                        link = LinkState.CONNECTED,
                        problem = null,
                    )
                }

                is TransportEvent.TextReceived -> acceptMessageLocked(event.text)
                is TransportEvent.Closed -> disconnectAndRetryLocked()
                is TransportEvent.Failed -> disconnectAndRetryLocked()
            }
        }
    }

    private fun acceptMessageLocked(text: String) {
        val envelope = runCatching { json.decodeFromString<IncomingEnvelope>(text) }
            .getOrElse {
                mutableState.value = mutableState.value.copy(
                    problem = PhoneSessionProblem.ProtocolFailure,
                )
                return
            }
        if (envelope.version != 1) {
            mutableState.value = mutableState.value.copy(
                problem = PhoneSessionProblem.ProtocolFailure,
            )
            return
        }
        when (envelope.type) {
            "state.snapshot" -> {
                if (
                    envelope.sentAt < lastSnapshotSentAt ||
                    envelope.messageId == lastSnapshotMessageID
                ) {
                    return
                }
                val snapshot = runCatching {
                    json.decodeFromJsonElement<StateSnapshotPayload>(envelope.payload)
                }.getOrElse {
                    mutableState.value = mutableState.value.copy(
                        problem = PhoneSessionProblem.ProtocolFailure,
                    )
                    return
                }
                lastSnapshotSentAt = envelope.sentAt
                lastSnapshotMessageID = envelope.messageId
                mutableState.value = mutableState.value.copy(
                    snapshot = snapshot,
                    problem = null,
                )
            }

            "control.ack" -> {
                val acknowledgment = runCatching {
                    json.decodeFromJsonElement<ControlAckPayload>(envelope.payload)
                }.getOrElse {
                    mutableState.value = mutableState.value.copy(
                        problem = PhoneSessionProblem.ProtocolFailure,
                    )
                    return
                }
                if (mutableState.value.controls[acknowledgment.requestID] !is ControlDelivery.Pending) {
                    return
                }
                timeoutJobs.remove(acknowledgment.requestID)?.cancel()
                updateControl(
                    acknowledgment.requestID,
                    ControlDelivery.Acknowledged(
                        result = acknowledgment.result,
                        reason = acknowledgment.reason,
                    ),
                )
            }
        }
    }

    private fun connectLocked(value: PairingPayload) {
        mutableState.value = mutableState.value.copy(link = LinkState.CONNECTING)
        transport.connect(PhoneEndpoint(value.host, value.port))
    }

    private fun disconnectAndRetryLocked() {
        mutableState.value = mutableState.value.copy(
            link = LinkState.DISCONNECTED,
            problem = PhoneSessionProblem.TransportFailure,
        )
        if (stopped || pairing == null || reconnectJob?.isActive == true) return
        val exponent = minOf(retryCount++, 5)
        val waitMillis = minOf(30_000L, 1_000L shl exponent)
        reconnectJob = scope.launch {
            wait(waitMillis)
            mutex.withLock {
                if (!stopped) {
                    pairing?.let(::connectLocked)
                }
                reconnectJob = null
            }
        }
    }

    private fun updateControl(requestID: String, delivery: ControlDelivery) {
        val controls = LinkedHashMap(mutableState.value.controls)
        controls[requestID] = delivery
        while (controls.size > MAX_CONTROL_HISTORY) {
            controls.remove(controls.keys.first())
        }
        mutableState.value = mutableState.value.copy(controls = controls)
    }

    private fun validatePairing(value: PairingPayload): PhoneSessionProblem? {
        if (value.version != 1) return PhoneSessionProblem.UnsupportedVersion
        if (value.host.isBlank() || value.port !in 1..65_535) {
            return PhoneSessionProblem.InvalidEndpoint
        }
        val validSecret = value.secret.isNotBlank() && runCatching {
            Base64.getDecoder().decode(value.secret)
        }.getOrNull()?.isNotEmpty() == true
        if (!validSecret) return PhoneSessionProblem.InvalidSecret
        return null
    }

    private val PairingPayload.summary: PairingSummary
        get() = PairingSummary(serviceID, host, port)

    @Serializable
    private data class IncomingEnvelope(
        val version: Int,
        val messageId: String,
        val type: String,
        val sentAt: Long,
        val payload: JsonElement,
    )

    private companion object {
        const val MAX_CONTROL_HISTORY = 50
    }
}
