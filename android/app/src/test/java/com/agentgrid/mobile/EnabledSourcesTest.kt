package com.agentgrid.mobile

import com.agentgrid.mobile.domain.*
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.*
import org.junit.Test

class EnabledSourcesTest {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    @Test fun `explicit source list overrides cached Claude task and previous visibility`() {
        val claude = TaskSnapshot("old-claude", AgentSource.CLAUDE_CODE, "old", lifecycle = AgentLifecycle.IDLE, startedAt = 1, updatedAt = 1)
        val payload = StateSnapshotPayload(listOf(claude), usage = UsageSnapshot(), hermesUsage = HermesUsageSnapshot(), enabledSources = listOf("codex", "hermes"))
        assertEquals(listOf("codex", "hermes"), EnabledDataSources.resolve(payload, listOf("claude")))
        assertEquals(emptyList<String>(), EnabledDataSources.resolve(payload.copy(enabledSources = emptyList()), listOf("codex", "hermes", "claude")))
    }

    @Test fun `legacy source detection needs positive evidence and retains it through empty snapshots`() {
        val empty = StateSnapshotPayload(emptyList())
        assertTrue(EnabledDataSources.resolve(empty).isEmpty())
        assertEquals(listOf("codex"), EnabledDataSources.resolve(empty.copy(usage = UsageSnapshot())))
        assertEquals(listOf("hermes"), EnabledDataSources.resolve(empty.copy(hermesUsage = HermesUsageSnapshot())))
        for ((source, expected) in listOf(AgentSource.CODEX_CLI to "codex", AgentSource.CODEX_DESKTOP to "codex", AgentSource.CLAUDE_CODE to "claude", AgentSource.HERMES_DESKTOP to "hermes")) {
            val task = TaskSnapshot("presence", source, "project", lifecycle = AgentLifecycle.OFFLINE, startedAt = 1, updatedAt = 1)
            val detected = EnabledDataSources.resolve(empty.copy(tasks = listOf(task)))
            assertEquals(listOf(expected), detected)
            assertEquals(detected, EnabledDataSources.resolve(empty, detected))
        }
    }

    @Test fun `wire retains explicit enabled sources including an explicitly empty list`() {
        assertNull(json.decodeFromString<StateSnapshotPayload>("""{"tasks":[]}""").enabledSources)
        assertNull(json.decodeFromString<StateSnapshotPayload>("""{"tasks":[],"enabledSources":null}""").enabledSources)
        for (sources in listOf("[\"codex\",\"hermes\"]", "[]")) {
            val payload = json.decodeFromString<StateSnapshotPayload>("""{"tasks":[],"enabledSources":$sources}""")
            assertEquals(json.parseToJsonElement(sources), json.parseToJsonElement(json.encodeToString(payload)).jsonObject["enabledSources"])
        }
    }
}
