import Foundation
import Testing
@testable import AgentGridCore

@Test("Claude Desktop 2.1.286 transcript 的 Stop 是完成证据")
func claudeDesktopTranscriptDetectsCompletedTurn() throws {
    let data = try #require(
        """
        {"type":"user","timestamp":"2026-10-05T08:06:40.100Z","message":{"role":"user","content":"测试状态"},"entrypoint":"claude-desktop"}
        {"type":"assistant","timestamp":"2026-10-05T08:06:50.100Z","message":{"role":"assistant","content":[]},"entrypoint":"claude-desktop"}
        {"type":"system","subtype":"stop_hook_summary","timestamp":"2026-10-05T08:06:58.613Z","hookCount":1,"hookErrors":[],"entrypoint":"claude-desktop"}
        """.data(using: .utf8)
    )
    let evidence = ClaudeTranscriptObservation.evidence(
        from: data,
        sessionID: "desktop-session",
        modificationDate: Date(timeIntervalSince1970: 100)
    )

    #expect(evidence.completedAt != nil)
    #expect(!evidence.hasOpenTurn)
}

@Test("Stop 后出现新用户消息表示新一轮仍在运行")
func claudeTranscriptDetectsOpenTurnAfterStop() throws {
    let data = try #require(
        """
        {"type":"user","timestamp":"2026-10-05T08:00:00Z"}
        {"type":"system","subtype":"stop_hook_summary","timestamp":"2026-10-05T08:01:00Z"}
        {"type":"user","timestamp":"2026-10-05T08:02:00Z","entrypoint":"claude-desktop"}
        """.data(using: .utf8)
    )
    let evidence = ClaudeTranscriptObservation.evidence(
        from: data,
        sessionID: "desktop-session",
        modificationDate: Date(timeIntervalSince1970: 100)
    )

    #expect(evidence.completedAt == nil)
    #expect(evidence.hasOpenTurn)
}

@Test("Claude 最终回复在缺少 Stop summary 时也能证明本轮完成")
func claudeFinalAssistantReplyCompletesTurn() {
    for reason in ["end_turn", "stop_sequence"] {
        let data = Data("""
        {"type":"user","timestamp":"2026-10-15T07:23:08Z"}
        {"type":"assistant","timestamp":"2026-10-15T07:23:11Z","message":{"role":"assistant","stop_reason":"\(reason)","content":[{"type":"text","text":"Done"}]}}
        """.utf8)
        let evidence = ClaudeTranscriptObservation.evidence(
            from: data,
            sessionID: "finished",
            modificationDate: .now
        )
        #expect(evidence.completedAt != nil)
        #expect(!evidence.hasOpenTurn)
    }
}

@Test("Stop 后继续生成工具调用时旧完成证据失效")
func claudeContinuingToolUseClearsOldCompletion() {
    let data = Data("""
    {"type":"system","subtype":"stop_hook_summary","timestamp":"2026-10-15T07:23:08Z"}
    {"type":"assistant","timestamp":"2026-10-15T07:23:11Z","message":{"role":"assistant","stop_reason":"tool_use","content":[]}}
    """.utf8)
    let evidence = ClaudeTranscriptObservation.evidence(
        from: data,
        sessionID: "continuing",
        modificationDate: .now
    )
    #expect(evidence.completedAt == nil)
    #expect(evidence.hasOpenTurn)
}

@Test("Claude 会话文件按 session id 查找并忽略其他会话")
func claudeTranscriptObservationFindsCandidates() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let project = root.appendingPathComponent("project", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data(
        "{\"type\":\"system\",\"subtype\":\"stop_hook_summary\",\"timestamp\":\"2026-10-05T08:01:00Z\"}\n".utf8
    ).write(to: project.appendingPathComponent("wanted.jsonl"))
    try Data("{\"type\":\"user\"}\n".utf8)
        .write(to: project.appendingPathComponent("other.jsonl"))

    let observation = ClaudeTranscriptObservation(projectsRoot: root)
    let result = observation.evidence(matching: ["wanted"])

    #expect(Set(result.keys) == ["wanted"])
    #expect(result["wanted"]?.completedAt != nil)
}
