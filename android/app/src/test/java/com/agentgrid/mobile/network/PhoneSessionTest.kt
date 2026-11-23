package com.agentgrid.mobile.network

import com.agentgrid.mobile.domain.AgentLifecycle
import com.agentgrid.mobile.domain.AgentSource
import com.agentgrid.mobile.domain.ControlAction
import com.agentgrid.mobile.domain.ControlResult
import com.agentgrid.mobile.domain.PairingPayload
import com.agentgrid.mobile.domain.SignedControlEnvelope
import com.agentgrid.mobile.domain.StateEnvelope
import com.agentgrid.mobile.domain.StateSnapshotPayload
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

    @Test
    fun `快照携带 Claude 额度时与 Codex 额度分别解码`() = runTest {
        val fixture = connectedFixture()
        fixture.transport.emit(
            TransportEvent.TextReceived(
                rawSnapshot(
                    "m1",
                    100,
                    """
                    "usage": {"capturedAt": 5000, "planType": "plus",
                      "windows": [{"key":"primary","label":"5h","usedPercentage":20,
                        "remainingPercentage":80,"windowMinutes":300,"resetsAt":9000}]},
                    "claudeUsage": {"capturedAt": 6000, "planType": "max",
                      "windows": [
                        {"key":"primary","label":"5h","usedPercentage":35.5,
                          "remainingPercentage":64.5,"windowMinutes":300,"resetsAt":9000},
                        {"key":"secondary","label":"7d","usedPercentage":10,
                          "remainingPercentage":90,"windowMinutes":10080}],
                      "dailyUsage": [{"date":"2026-10-18","totalTokens":1234}]},
                    """,
                ),
            ),
        )
        runCurrent()

        val snapshot = fixture.session.state.value.snapshot
        assertEquals("plus", snapshot.usage?.planType)
        assertEquals(1, snapshot.usage?.windows?.size)
        val claude = snapshot.claudeUsage!!
        assertEquals("max", claude.planType)
        assertEquals(listOf("primary", "secondary"), claude.windows.map { it.key })
        assertEquals(64.5, claude.windows[0].remainingPercentage, 0.0001)
        assertEquals(null, claude.windows[1].resetsAt)
        assertEquals(1234L, claude.dailyUsage.single().totalTokens)
        assertEquals(null, claude.dailyUsage.single().estimatedCostUSD)
        fixture.close()
    }

    @Test
    fun `旧版 Bridge 不发送 Claude 额度时仍可解码 Codex 额度`() = runTest {
        val fixture = connectedFixture()
        fixture.transport.emit(
            TransportEvent.TextReceived(
                rawSnapshot(
                    "m1",
                    100,
                    """"usage": {"windows": [{"key":"primary","label":"5h",
                        "usedPercentage":1,"remainingPercentage":99,"windowMinutes":300}]},""",
                ),
            ),
        )
        runCurrent()

        val snapshot = fixture.session.state.value.snapshot
        assertEquals(null, fixture.session.state.value.problem)
        assertEquals(99.0, snapshot.usage!!.windows.single().remainingPercentage, 0.0001)
        assertEquals(null, snapshot.claudeUsage)
        fixture.close()
    }

    @Test
    fun `Claude 额度为空对象或显式 null 时不会丢弃整条快照`() = runTest {
        val fixture = connectedFixture()
        fixture.transport.emit(
            TransportEvent.TextReceived(rawSnapshot("m1", 100, """"claudeUsage": {},""")),
        )
        runCurrent()
        assertEquals(null, fixture.session.state.value.problem)
        assertEquals(emptyList<Any>(), fixture.session.state.value.snapshot.claudeUsage?.windows)

        fixture.transport.emit(
            TransportEvent.TextReceived(rawSnapshot("m2", 200, """"claudeUsage": null,""")),
        )
        runCurrent()
        assertEquals(null, fixture.session.state.value.problem)
        assertEquals(null, fixture.session.state.value.snapshot.claudeUsage)
        fixture.close()
    }

    @Test
    fun `未知枚举值回退默认值且终态缺完成时间不会让快照失败`() = runTest {
        val fixture = connectedFixture()
        fixture.transport.emit(
            TransportEvent.TextReceived(
                """
                {"version":1,"messageId":"m1","type":"state.snapshot","sentAt":100,
                 "payload":{"tasks":[{"id":"t","source":"codexCLI","projectName":"P",
                   "lifecycle":"succeeded","activity":"someFutureActivity",
                   "capabilities":["approve","futureCapability"],
                   "tokenUsage":{"total":5000000000},
                   "startedAt":10,"updatedAt":50}]}}
                """.trimIndent(),
            ),
        )
        runCurrent()

        assertEquals(null, fixture.session.state.value.problem)
        val task = fixture.session.state.value.snapshot.tasks.single()
        assertEquals(null, task.activity)
        assertEquals(5_000_000_000L, task.tokenUsage?.total)
        assertEquals(40L, task.elapsedAt(now = 9_999))
        fixture.close()
    }

    @Test
    fun `重新连接后第一帧快照即使 sentAt 更早也会被接受`() = runTest {
        val fixture = connectedFixture()
        fixture.transport.emit(
            TransportEvent.TextReceived(snapshotEnvelope("a", 500, "before")),
        )
        runCurrent()
        fixture.transport.emit(TransportEvent.Failed("断开"))
        runCurrent()
        advanceTimeBy(1_000)
        runCurrent()
        fixture.transport.emit(TransportEvent.Opened)
        fixture.transport.emit(
            TransportEvent.TextReceived(snapshotEnvelope("b", 100, "after")),
        )
        runCurrent()

        assertEquals(
            listOf("after"),
            fixture.session.state.value.snapshot.tasks.map { it.id },
        )
        fixture.close()
    }

    private fun rawSnapshot(messageID: String, sentAt: Long, payloadFields: String): String =
        """
        {"version":1,"messageId":"$messageID","type":"state.snapshot","sentAt":$sentAt,
         "payload":{$payloadFields "tasks":[]}}
        """.trimIndent()

    private suspend fun kotlinx.coroutines.test.TestScope.connectedFixture(): Fixture {
        val fixture = fixture(pairing())
        fixture.session.start()
        runCurrent()
        fixture.transport.emit(TransportEvent.Opened)
        runCurrent()
        return fixture
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
