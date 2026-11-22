package com.agentgrid.mobile.network

import com.agentgrid.mobile.domain.AgentActivity
import com.agentgrid.mobile.domain.AgentLifecycle
import com.agentgrid.mobile.domain.AgentSource
import com.agentgrid.mobile.domain.ControlAction
import com.agentgrid.mobile.domain.ControlResult
import com.agentgrid.mobile.domain.PairingPayload
import com.agentgrid.mobile.domain.SignedControlEnvelope
import com.agentgrid.mobile.domain.StateEnvelope
import com.agentgrid.mobile.domain.StateSnapshotPayload
import com.agentgrid.mobile.domain.TaskDashboardProjector
import com.agentgrid.mobile.domain.TaskSnapshot
import java.util.Base64
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class PhoneSessionTest {
    private val json = Json {
        encodeDefaults = true
        explicitNulls = false
    }

    @Test
    fun `启动会恢复配对并连接到保存的端点`() = runTest {
        val fixture = fixture(pairing = pairing())

        fixture.session.start()
        runCurrent()

        assertEquals(LinkState.CONNECTING, fixture.session.state.value.link)
        assertEquals(PairingSummary("bridge", "127.0.0.1", 8765), fixture.session.state.value.pairing)
        assertEquals(listOf(PhoneEndpoint("127.0.0.1", 8765)), fixture.transport.connections)

        fixture.transport.emit(TransportEvent.Opened)
        runCurrent()

        assertEquals(LinkState.CONNECTED, fixture.session.state.value.link)
        fixture.close()
    }

    @Test
    fun `损坏凭据会失败关闭并清除不可解密内容`() = runTest {
        val fixture = fixture(pairing = pairing())
        fixture.credentials.loadFails = true

        fixture.session.start()
        runCurrent()

        assertEquals(
            PhoneSessionProblem.CredentialFailure,
            fixture.session.state.value.problem,
        )
        assertTrue(fixture.credentials.cleared)
        assertTrue(fixture.transport.connections.isEmpty())
        fixture.close()
    }

    @Test
    fun `配对先保存凭据再替换连接且会校验端点和密钥`() = runTest {
        val fixture = fixture()
        fixture.session.start()
        runCurrent()

        val invalid = fixture.session.pair(
            json.encodeToString(pairing().copy(port = 0)),
        )
        val accepted = fixture.session.pair(json.encodeToString(pairing()))

        assertEquals(
            PairingOutcome.Rejected(PhoneSessionProblem.InvalidEndpoint),
            invalid,
        )
        assertEquals(PairingOutcome.Connecting, accepted)
        assertEquals(listOf("保存凭据", "连接端点"), fixture.operationLog)
        fixture.close()
    }

    @Test
    fun `Windows secure pairing version is accepted and reconnected`() = runTest {
        val fixture = fixture()
        try {
            val encoded = """{"version":2,"serviceID":"windows-fixture","host":"127.0.0.1","port":49365,"secret":"${Base64.getEncoder().encodeToString(SECRET)}","certificateSha256":"${"ab".repeat(32)}"}"""
            assertEquals(PairingOutcome.Connecting, fixture.session.pair(encoded))
            fixture.transport.emit(TransportEvent.Failed(null))
            runCurrent()
            advanceTimeBy(1_001)
            assertEquals(2, fixture.transport.connections.size)
            assertEquals("ab".repeat(32), fixture.transport.connections.first().tls?.certificateSha256)
            assertEquals(fixture.transport.connections.first(), fixture.transport.connections.last())
        } finally { fixture.close() }
    }

    @Test
    fun `malformed secure QR cannot connect or replace saved pairing`() = runTest {
        val fixture = fixture(pairing())
        try {
            fixture.session.start()
            val valid = pairing().copy(version = 2, certificateSha256 = "ab".repeat(32))
            val invalid = listOf(
                valid.copy(certificateSha256 = null),
                valid.copy(certificateSha256 = "bad-pin"),
                valid.copy(version = 1),
                valid.copy(host = "127.0.0.1/agentgrid"),
                valid.copy(host = "attacker.invalid@127.0.0.1"),
                valid.copy(secret = "YQ=="),
            )
            invalid.forEach {
                assertTrue(fixture.session.pair(json.encodeToString(it)) is PairingOutcome.Rejected)
            }
            assertEquals(listOf(PhoneEndpoint("127.0.0.1", 8765)), fixture.transport.connections)
            assertEquals(pairing(), fixture.credentials.load())
        } finally { fixture.close() }
    }

    @Test
    fun `控制请求消耗持久序号完成签名并关联首次确认`() = runTest {
        val fixture = connectedFixture()

        val submission = fixture.session.control(
            taskID = "task-1",
            action = ControlAction.APPROVE,
        ) as ControlSubmission.Queued
        val envelope = json.decodeFromString<SignedControlEnvelope>(
            fixture.transport.sentTexts.single(),
        )

        assertEquals(1uL, envelope.sequence)
        assertEquals("request-1", envelope.messageId)
        assertEquals("nonce-1", envelope.nonce)
        assertEquals(
            ControlSigner.sign(envelope.copy(signature = ""), SECRET),
            envelope.signature,
        )
        assertTrue(
            fixture.session.state.value.controls[submission.requestID] is
                ControlDelivery.Pending,
        )

        fixture.transport.emit(
            TransportEvent.TextReceived(
                """
                {
                  "version": 1,
                  "messageId": "ack-1",
                  "type": "control.ack",
                  "sentAt": 1100,
                  "payload": {
                    "requestID": "${submission.requestID}",
                    "result": "accepted"
                  }
                }
                """.trimIndent(),
            ),
        )
        runCurrent()

        assertEquals(
            ControlDelivery.Acknowledged(ControlResult.ACCEPTED, null),
            fixture.session.state.value.controls[submission.requestID],
        )
        fixture.close()
    }

    @Test
    fun `发送失败仍烧掉序号且下次请求严格递增`() = runTest {
        val fixture = connectedFixture()
        fixture.transport.sendAccepted = false

        val failed = fixture.session.control("task-1", ControlAction.DENY)
        fixture.transport.sendAccepted = true
        val queued = fixture.session.control("task-1", ControlAction.APPROVE)
        val secondEnvelope = json.decodeFromString<SignedControlEnvelope>(
            fixture.transport.sentTexts.last(),
        )

        assertEquals(
            ControlSubmission.Rejected(PhoneSessionProblem.TransportFailure),
            failed,
        )
        assertTrue(queued is ControlSubmission.Queued)
        assertEquals(2uL, secondEnvelope.sequence)
        assertEquals(2uL, fixture.credentials.sequence)
        fixture.close()
    }

    @Test
    fun `解除后重新配对仍延续设备控制序号`() = runTest {
        val fixture = connectedFixture()
        fixture.session.control("task-1", ControlAction.APPROVE)

        fixture.session.unpair()
        fixture.session.pair(json.encodeToString(pairing()))
        fixture.transport.emit(TransportEvent.Opened)
        runCurrent()
        fixture.session.control("task-2", ControlAction.DENY)
        val envelope = json.decodeFromString<SignedControlEnvelope>(
            fixture.transport.sentTexts.last(),
        )

        assertEquals(2uL, envelope.sequence)
        fixture.close()
    }

    @Test
    fun `乱序或重复快照不能让会话状态回退`() = runTest {
        val fixture = connectedFixture()
        fixture.transport.emit(
            TransportEvent.TextReceived(snapshotEnvelope("new", 200, "new-task")),
        )
        runCurrent()
        fixture.transport.emit(
            TransportEvent.TextReceived(snapshotEnvelope("old", 100, "old-task")),
        )
        fixture.transport.emit(
            TransportEvent.TextReceived(snapshotEnvelope("new", 300, "duplicate-task")),
        )
        runCurrent()

        assertEquals(
            listOf("new-task"),
            fixture.session.state.value.snapshot.tasks.map { it.id },
        )
        fixture.close()
    }

    @Test
    fun `未确认控制会超时且晚到确认不能覆盖超时`() = runTest {
        val fixture = connectedFixture()
        val queued = fixture.session.control(
            "task-1",
            ControlAction.INTERRUPT,
        ) as ControlSubmission.Queued

        advanceTimeBy(15_000)
        runCurrent()
        fixture.transport.emit(
            TransportEvent.TextReceived(
                """
                {
                  "version": 1,
                  "messageId": "late-ack",
                  "type": "control.ack",
                  "sentAt": 20000,
                  "payload": {
                    "requestID": "${queued.requestID}",
                    "result": "accepted"
                  }
                }
                """.trimIndent(),
            ),
        )
        runCurrent()

        assertEquals(
            ControlDelivery.TimedOut,
            fixture.session.state.value.controls[queued.requestID],
        )
        fixture.close()
    }

    @Test
    fun `断线只安排一个重连且解除配对会清空会话`() = runTest {
        val fixture = connectedFixture()
        fixture.transport.emit(TransportEvent.Failed("网络断开"))
        fixture.transport.emit(TransportEvent.Closed("重复回调"))
        runCurrent()

        assertEquals(1, fixture.transport.connections.size)
        advanceTimeBy(1_000)
        runCurrent()
        assertEquals(2, fixture.transport.connections.size)

        fixture.session.unpair()

        assertTrue(fixture.credentials.cleared)
        assertEquals(PhoneSessionState(), fixture.session.state.value)
        assertFalse(fixture.transport.connected)
        fixture.close()
    }

    private suspend fun kotlinx.coroutines.test.TestScope.connectedFixture(): Fixture {
        val fixture = fixture(pairing())
        fixture.session.start()
        runCurrent()
        fixture.transport.emit(TransportEvent.Opened)
        runCurrent()
        return fixture
    }

    @Test
    fun `Windows网页监测实际快照能被安卓解码并投影为独立任务`() = runTest {
        val fixture = connectedFixture()
        try {
            val frame = checkNotNull(javaClass.getResourceAsStream("/chatgpt-web-bridge-frame.json"))
                .bufferedReader().use { it.readText() }
            fixture.transport.emit(TransportEvent.TextReceived(frame))
            runCurrent()

            val state = fixture.session.state.value
            assertEquals(null, state.problem)
            val snapshot = checkNotNull(state.snapshot)
            val dashboard = TaskDashboardProjector.project(snapshot, previous = null, now = snapshot.tasks.maxOf { it.updatedAt })
            val chat = dashboard.visibleTasks.single { it.projectName == "ChatGPT Chat" }
            val work = dashboard.visibleTasks.single { it.projectName == "ChatGPT Work" }
            assertEquals(AgentSource.CODEX_DESKTOP, chat.source)
            assertEquals("Fixture Beta", chat.title)
            assertEquals(AgentActivity.THINKING, chat.activity)
            assertEquals(AgentLifecycle.RUNNING, chat.lifecycle)
            assertEquals(AgentLifecycle.SUCCEEDED, work.lifecycle)
            assertFalse(dashboard.dashboardVisible)
        } finally { fixture.close() }
    }

    private fun kotlinx.coroutines.test.TestScope.fixture(
        pairing: PairingPayload? = null,
    ): Fixture {
        val operationLog = mutableListOf<String>()
        val credentials = InMemoryCredentialStore(pairing, operationLog)
        val transport = InMemoryPhoneSessionTransport(operationLog)
        val scope = CoroutineScope(SupervisorJob() + StandardTestDispatcher(testScheduler))
        var requestIndex = 0
        val session = DefaultPhoneSession(
            credentialStore = credentials,
            transport = transport,
            deviceID = "android-test",
            scope = scope,
            now = { 1_000L },
            requestID = { "request-${++requestIndex}" },
            nonce = { "nonce-$requestIndex" },
        )
        runCurrent()
        return Fixture(session, credentials, transport, operationLog)
    }

    private fun pairing() = PairingPayload(
        version = 1,
        serviceID = "bridge",
        host = "127.0.0.1",
        port = 8765,
        secret = Base64.getEncoder().encodeToString(SECRET),
    )

    private fun snapshotEnvelope(messageID: String, sentAt: Long, taskID: String): String =
        json.encodeToString(
            StateEnvelope(
                version = 1,
                messageId = messageID,
                type = "state.snapshot",
                sentAt = sentAt,
                payload = StateSnapshotPayload(
                    tasks = listOf(
                        TaskSnapshot(
                            id = taskID,
                            source = AgentSource.CODEX_CLI,
                            projectName = "AgentGrid",
                            lifecycle = AgentLifecycle.RUNNING,
                            startedAt = 0,
                            updatedAt = sentAt,
                        ),
                    ),
                ),
            ),
        )

    private data class Fixture(
        val session: DefaultPhoneSession,
        val credentials: InMemoryCredentialStore,
        val transport: InMemoryPhoneSessionTransport,
        val operationLog: List<String>,
    ) {
        fun close() = session.close()
    }

    private class InMemoryCredentialStore(
        private var pairing: PairingPayload?,
        private val operationLog: MutableList<String>,
    ) : PhoneCredentialStore {
        var sequence = 0uL
        var cleared = false
        var loadFails = false

        override suspend fun load(): PairingPayload? {
            check(!loadFails) { "凭据损坏" }
            return pairing
        }

        override suspend fun save(pairing: PairingPayload) {
            operationLog += "保存凭据"
            this.pairing = pairing
        }

        override suspend fun clear() {
            cleared = true
            pairing = null
        }

        override suspend fun reserveNextSequence(): ULong {
            sequence += 1u
            return sequence
        }
    }

    private class InMemoryPhoneSessionTransport(
        private val operationLog: MutableList<String>,
    ) : PhoneSessionTransport {
        private val mutableEvents = MutableSharedFlow<TransportEvent>(
            extraBufferCapacity = 32,
        )
        override val events: Flow<TransportEvent> = mutableEvents
        val connections = mutableListOf<PhoneEndpoint>()
        val sentTexts = mutableListOf<String>()
        var sendAccepted = true
        var connected = false

        override fun connect(endpoint: PhoneEndpoint) {
            operationLog += "连接端点"
            connections += endpoint
            connected = true
        }

        override fun send(text: String): Boolean {
            sentTexts += text
            return sendAccepted
        }

        override fun disconnect() {
            connected = false
        }

        override fun close() = Unit

        fun emit(event: TransportEvent) {
            check(mutableEvents.tryEmit(event))
        }
    }

    private companion object {
        val SECRET = ByteArray(32) { 0x42 }
    }
}
