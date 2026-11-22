package com.agentgrid.mobile

import com.agentgrid.mobile.domain.AgentActivity
import com.agentgrid.mobile.domain.AgentLifecycle
import com.agentgrid.mobile.domain.AgentSource
import com.agentgrid.mobile.domain.StateEnvelope
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class HermesSourceTest {
    private val json = Json { ignoreUnknownKeys = true }

    @Test
    fun `Hermes 桌面任务可以与现有来源一起解析且默认为只读`() {
        val envelope = json.decodeFromString<StateEnvelope>(
            """
            {
              "version": 1,
              "messageId": "hermes-snapshot",
              "type": "state.snapshot",
              "sentAt": 2000,
              "payload": {
                "tasks": [
                  {
                    "id": "hermes-session-1",
                    "source": "hermesDesktop",
                    "projectName": "AgentPager",
                    "title": "Hermes desktop task",
                    "latestStep": "Reading project files",
                    "lifecycle": "running",
                    "activity": "reading",
                    "startedAt": 1000,
                    "updatedAt": 2000
                  },
                  {
                    "id": "codex-session-1",
                    "source": "codexCLI",
                    "projectName": "AgentPager",
                    "lifecycle": "idle",
                    "startedAt": 1000,
                    "updatedAt": 2000
                  }
                ]
              }
            }
            """.trimIndent(),
        )

        assertEquals(2, envelope.payload.tasks.size)
        val hermes = envelope.payload.tasks.first()
        assertEquals("HERMES_DESKTOP", hermes.source.name)
        assertEquals("Hermes desktop task", hermes.title)
        assertEquals("Reading project files", hermes.latestStep)
        assertEquals(AgentLifecycle.RUNNING, hermes.lifecycle)
        assertEquals(AgentActivity.READING, hermes.activity)
        assertTrue(hermes.capabilities.isEmpty())
        assertEquals(AgentSource.CODEX_CLI, envelope.payload.tasks.last().source)
    }

    @Test
    fun `Hermes 来源序列化保留精确协议名称且不影响现有来源`() {
        val wireNames = mapOf(
            "codexDesktop" to "CODEX_DESKTOP",
            "codexCLI" to "CODEX_CLI",
            "claudeCode" to "CLAUDE_CODE",
            "hermesDesktop" to "HERMES_DESKTOP",
        )

        wireNames.forEach { (wireName, enumName) ->
            val encoded = "\"$wireName\""
            val source = json.decodeFromString<AgentSource>(encoded)
            assertEquals(enumName, source.name)
            assertEquals(encoded, json.encodeToString(source))
        }
    }
}
