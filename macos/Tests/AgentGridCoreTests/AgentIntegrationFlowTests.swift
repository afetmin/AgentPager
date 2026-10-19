import Foundation
import Testing
@testable import AgentGridCore

@Test("兼容客户端的任务带 agentName，Claude Code 本身没有")
func reducerRecordsAgentName() {
    var hook = ClaudeHookPayload(
        cwd: "/tmp/agentpager", hookEventName: "UserPromptSubmit", sessionID: "z-1", prompt: "修复"
    )
    #expect(ClaudeEventReducer.task(from: hook, existing: nil).agentName == nil)

    hook.integrationID = "zcode"
    let task = ClaudeEventReducer.task(from: hook, existing: nil)
    #expect(task.source == .claudeCode)
    #expect(task.agentName == "ZCode")
}

@Test("线上只在有值时携带 agentName，旧版手机端看到的仍是 claudeCode")
func snapshotEncodesAgentNameOnlyWhenPresent() throws {
    let plain = TaskSnapshot(id: "a", source: .claudeCode, projectName: "p", lifecycle: .running)
    let named = TaskSnapshot(
        id: "b", source: .claudeCode, projectName: "p", lifecycle: .running, agentName: "ZCode"
    )
    let encoder = JSONEncoder()
    let plainObject = try #require(
        JSONSerialization.jsonObject(with: encoder.encode(plain)) as? [String: Any]
    )
    let namedObject = try #require(
        JSONSerialization.jsonObject(with: encoder.encode(named)) as? [String: Any]
    )
    #expect(plainObject["agentName"] == nil)
    #expect(namedObject["agentName"] as? String == "ZCode")
    #expect(namedObject["source"] as? String == "claudeCode")
}

@Test("agentName 随任务快照持久化往返")
func agentNameSurvivesPersistence() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let persistence = TaskSnapshotPersistence(fileURL: url)
    try persistence.save([
        TaskSnapshot(
            id: "b", source: .claudeCode, projectName: "p", lifecycle: .succeeded, agentName: "WorkBuddy"
        ),
    ])
    #expect(persistence.load().first?.agentName == "WorkBuddy")
}

@Test("兼容客户端的运行中任务不按 Claude 会话文件规则被收敛为中断")
func compatibleAgentTasksAreNotReconciledAgainstClaudeTranscripts() {
    let now = Date(timeIntervalSince1970: 200_000)
    // 超过 10 分钟静默阈值，但仍在终态任务的保留期内。
    let old = now.addingTimeInterval(-700)
    let compatible = TaskSnapshot(
        id: "zcode-run", source: .claudeCode, projectName: "p",
        lifecycle: .running, activity: .executing, startedAt: old, updatedAt: old,
        agentName: "ZCode"
    )
    let claude = TaskSnapshot(
        id: "claude-run", source: .claudeCode, projectName: "p",
        lifecycle: .running, activity: .executing, startedAt: old, updatedAt: old
    )
    // 近期活跃的任务让目录以 `now` 为基准整理，旧的终态任务才不会被直接清掉。
    let anchor = TaskSnapshot(
        id: "anchor", source: .codexCLI, projectName: "p",
        lifecycle: .running, activity: .thinking, startedAt: now, updatedAt: now
    )
    var catalog = TaskCatalog(restoring: [compatible, claude, anchor])
    _ = catalog.reconcileClaudeSessions(evidenceBySessionID: [:], now: now)

    let byID = Dictionary(uniqueKeysWithValues: catalog.projection().tasks.map { ($0.id, $0) })
    #expect(byID["zcode-run"]?.lifecycle == .running)
    #expect(byID["claude-run"]?.lifecycle == .interrupted)
}
