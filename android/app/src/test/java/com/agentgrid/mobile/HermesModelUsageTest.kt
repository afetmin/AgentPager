package com.agentgrid.mobile

import com.agentgrid.mobile.domain.TaskSnapshot
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.*
import org.junit.Test

class HermesModelUsageTest {
    private val json = Json { ignoreUnknownKeys = true }
    private val fixture = """{"id":"hermes-desktop:session:test","source":"hermesDesktop","projectName":"Hermes Desktop","lifecycle":"running","startedAt":1000,"updatedAt":2000,
      "modelUsage":{"model":"model-a","provider":"provider-a","inputTokens":100,"outputTokens":20,"totalTokens":120,"estimatedCostUSD":0.25,"costSource":"current_model_pricing","quota":{"label":"Today","usedPercentage":12.5,"resetsAt":9999999999999,"source":"session_plan_gauge"}}} """

    @Test fun `native Hermes metadata survives phone decoding without affecting legacy cards`() {
        val task = json.decodeFromString<TaskSnapshot>(fixture)
        val fields = json.parseToJsonElement(json.encodeToString(task)).jsonObject
        assertTrue("Native model usage must reach the phone", fields.containsKey("modelUsage"))
        assertEquals("0.25", fields.getValue("modelUsage").jsonObject.getValue("estimatedCostUSD").toString())
        assertTrue(task.capabilities.isEmpty())
        val legacy = json.decodeFromString<TaskSnapshot>("""{"id":"old","source":"codexCLI","projectName":"old","lifecycle":"idle","startedAt":1,"updatedAt":1}""")
        assertFalse(json.parseToJsonElement(json.encodeToString(legacy)).jsonObject.containsKey("modelUsage"))
    }
}
