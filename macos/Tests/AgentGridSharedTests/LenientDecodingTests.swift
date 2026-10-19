import Foundation
import Testing
@testable import AgentGridShared

private func decode(_ json: String) throws -> StateSnapshotPayload {
    try ProtocolCodec.makeDecoder().decode(StateSnapshotPayload.self, from: Data(json.utf8))
}

private func task(_ extra: String = "", id: String = "t1", lifecycle: String = "running") -> String {
    """
    {"id":"\(id)","source":"codexCLI","projectName":"P","lifecycle":"\(lifecycle)",
     "startedAt":1000,"updatedAt":2000\(extra)}
    """
}

@Test("共享协议夹具 task-snapshot.json 可以解码")
func decodesProtocolFixture() throws {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: "protocol/fixtures/task-snapshot.json")
    let envelope = try ProtocolCodec.makeDecoder().decode(
        MessageEnvelope<StateSnapshotPayload>.self,
        from: Data(contentsOf: url)
    )

    let task = try #require(envelope.payload.tasks.first)
    #expect(task.id == "task-fixture")
    #expect(task.title == "AgentPager")
    #expect(task.capabilities == [.interrupt])
    #expect(task.subagents.isEmpty)
    #expect(envelope.payload.pendingRequests.isEmpty)
}

@Test("未知的任务能力被忽略，其余能力保留")
func unknownCapabilitiesAreDropped() throws {
    let snapshot = try decode(#"{"tasks":[\#(task(#","capabilities":["approve","teleport","deny"]"#))]}"#)

    #expect(snapshot.tasks.first?.capabilities == [.approve, .deny])
}

@Test("未知的活动回退为空，不影响任务")
func unknownActivityFallsBack() throws {
    let snapshot = try decode(#"{"tasks":[\#(task(#","activity":"daydreaming""#))]}"#)

    #expect(snapshot.tasks.count == 1)
    #expect(snapshot.tasks.first?.activity == nil)
}

@Test("无法识别的任务被单独跳过，不会清空整个快照")
func badTasksAreSkipped() throws {
    let snapshot = try decode(
        #"{"tasks":[\#(task(id: "ok1")),\#(task(id: "bad", lifecycle: "levitating")),{"id":5},\#(task(id: "ok2"))]}"#
    )

    #expect(snapshot.tasks.map(\.id) == ["ok1", "ok2"])
}

@Test("无法识别的用量和待处理请求不影响任务")
func badUsageAndRequestsAreTolerated() throws {
    let snapshot = try decode(
        #"""
        {"tasks":[\#(task())],"usage":{"windows":"oops"},"claudeUsage":7,
         "pendingRequests":[{"taskID":"t1","kind":"approval","summary":"ls"},{"taskID":"t2","kind":"???"}]}
        """#
    )

    #expect(snapshot.tasks.count == 1)
    #expect(snapshot.usage == nil)
    #expect(snapshot.claudeUsage == nil)
    #expect(snapshot.pendingRequests.map(\.taskID) == ["t1"])
}

@Test("子代理和 Token 字段缺省时使用默认值")
func missingNestedFieldsUseDefaults() throws {
    let snapshot = try decode(
        #"""
        {"tasks":[\#(task(#","tokenUsage":{"total":42},"subagents":[{"id":"s","path":"/root/code_reviewer","startedAt":1,"updatedAt":2},{"nonsense":true}]"#))]}
        """#
    )

    let task = try #require(snapshot.tasks.first)
    #expect(task.tokenUsage?.total == 42)
    #expect(task.tokenUsage?.input == 0)
    #expect(task.subagents.count == 1)
    #expect(task.subagents.first?.displayName == "Code reviewer")
    #expect(task.subagents.first?.lifecycle == .running)
}

@Test("完整快照编码后再解码保持不变")
func fullSnapshotRoundTrips() throws {
    let original = StateSnapshotPayload(
        tasks: [TaskSnapshot(
            id: "t",
            source: .claudeCode,
            projectName: "P",
            title: "T",
            userPrompt: "u",
            latestStep: "s",
            tokenUsage: TokenUsage(input: 1, cachedInput: 2, output: 3, reasoningOutput: 4, total: 10),
            subagents: [SubagentSnapshot(id: "s", path: "/a", startedAt: Date(timeIntervalSince1970: 5), updatedAt: Date(timeIntervalSince1970: 6))],
            lifecycle: .waitingApproval,
            activity: .editing,
            startedAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2),
            isUnread: true,
            capabilities: [.approve, .deny]
        )],
        usage: nil,
        focusedTaskID: "t",
        pendingRequests: [PendingRequest(taskID: "t", kind: .question, summary: "?", options: ["a"])]
    )

    let decoded = try ProtocolCodec.makeDecoder().decode(
        StateSnapshotPayload.self,
        from: ProtocolCodec.encode(original)
    )

    #expect(decoded == original)
}
