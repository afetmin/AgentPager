package com.agentgrid.mobile.domain

import kotlinx.serialization.Serializable

/** SDK-exported session counters. Cost is an estimate, never an invoice or subscription charge. */
@Serializable
data class SessionModelUsage(
    val inputTokens: Int,
    val outputTokens: Int,
    val totalTokens: Int,
    val model: String? = null,
    val provider: String? = null,
    val estimatedCostUSD: Double? = null,
    val costSource: String? = null,
    val quota: SessionQuota? = null,
)

@Serializable
data class SessionQuota(
    val label: String,
    val usedPercentage: Double,
    val source: String,
    val resetsAt: Long? = null,
)
