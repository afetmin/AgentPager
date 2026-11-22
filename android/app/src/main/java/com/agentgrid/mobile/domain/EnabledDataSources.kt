package com.agentgrid.mobile.domain

/** Bridge declarations are authoritative, including an explicitly empty list. */
internal object EnabledDataSources {
    fun resolve(snapshot: StateSnapshotPayload, previous: List<String> = emptyList()): List<String> =
        snapshot.enabledSources ?: buildList {
            addAll(previous)
            if (snapshot.usage != null) add("codex")
            if (snapshot.hermesUsage != null) add("hermes")
            snapshot.tasks.forEach { task ->
                add(when (task.source) {
                    AgentSource.CODEX_CLI, AgentSource.CODEX_DESKTOP -> "codex"
                    AgentSource.CLAUDE_CODE -> "claude"
                    AgentSource.HERMES_DESKTOP -> "hermes"
                })
            }
        }.distinct()
}
