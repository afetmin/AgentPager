import Foundation
import Testing
@testable import AgentGridCore

@Test("Hook 审批在同一投影中提交任务和待处理请求")
func hookApprovalCommitsConsistentProjection() {
    let now = Date(timeIntervalSince1970: 1_000)
    let hook = CodexHookPayload(
        cwd: "/tmp/AgentGrid",
        hookEventName: .permissionRequest,
        sessionID: "session-1",
        toolName: "exec_command"
    )
    var catalog = TaskCatalog()

    let changed = catalog.accept(.hook(hook, receivedAt: now))
    let projection = catalog.projection()

    #expect(changed)
    #expect(projection.revision == 1)
    #expect(projection.tasks.count == 1)
    #expect(projection.tasks[0].lifecycle == .waitingApproval)
    #expect(projection.tasks[0].capabilities == [.approve, .deny])
    #expect(projection.pendingRequests == [
        PendingRequest(
            taskID: "session-1",
            kind: .approval,
            summary: nil
        ),
    ])
}

@Test("批准控制先解析 Hook 再原子提交运行态")
func approvalControlResolvesBeforeCommit() {
    let now = Date(timeIntervalSince1970: 2_000)
    let hook = CodexHookPayload(
        cwd: "/tmp/AgentGrid",
        hookEventName: .permissionRequest,
        sessionID: "session-1",
        toolName: "exec_command"
    )
    let resolver = RecordingPermissionResolver()
    var catalog = TaskCatalog()
    catalog.accept(.hook(hook, receivedAt: now))

    let receipt = catalog.perform(
        AuthorizedTaskControl(
            requestID: UUID(),
            taskID: "session-1",
            action: .approve
        ),
        permissionResolver: resolver,
        now: now.addingTimeInterval(1)
    )
    let projection = catalog.projection()

    #expect(receipt.result == .accepted)
    #expect(receipt.committedRevision == 2)
    #expect(resolver.decisions == [
        .init(sessionID: "session-1", decision: .allow),
    ])
    #expect(projection.tasks[0].lifecycle == .running)
    #expect(projection.tasks[0].capabilities.isEmpty)
    #expect(projection.pendingRequests.isEmpty)
}

@Test("Hook 解析失败时控制不会提前修改 Task")
func failedPermissionResolutionKeepsState() {
    let hook = CodexHookPayload(
        cwd: "/tmp/AgentGrid",
        hookEventName: .permissionRequest,
        sessionID: "session-1",
        toolName: "exec_command"
    )
    let resolver = RecordingPermissionResolver(shouldFail: true)
    var catalog = TaskCatalog()
    catalog.accept(.hook(hook))
    let before = catalog.projection()

    let receipt = catalog.perform(
        AuthorizedTaskControl(
            requestID: UUID(),
            taskID: "session-1",
            action: .deny
        ),
        permissionResolver: resolver
    )

    #expect(receipt.result == .rejected)
    #expect(catalog.projection() == before)
}

@Test("旧 rollout 不会把终态 Task 重新打开")
func staleRolloutDoesNotReopenTerminalTask() {
    let completedAt = Date.now
    let task = TaskSnapshot(
        id: "session-1",
        source: .codexCLI,
        projectName: "AgentGrid",
        lifecycle: .succeeded,
        updatedAt: completedAt,
        completedAt: completedAt,
        isUnread: true
    )
    let staleSignal = CodexRolloutSignal(
        sessionID: "session-1",
        cwd: "/tmp/AgentGrid",
        lifecycle: .running,
        activity: .thinking,
        userPrompt: "可以补充的旧消息",
        timestamp: completedAt.addingTimeInterval(-10)
    )
    var catalog = TaskCatalog(restoring: [task])

    catalog.accept(.rollout([staleSignal]))
    let updated = catalog.projection().tasks[0]

    #expect(updated.lifecycle == .succeeded)
    #expect(updated.completedAt == completedAt)
    #expect(updated.userPrompt == "可以补充的旧消息")
}

@Test("新一轮用户输入会把已完成 Task 重新打开")
func freshUserMessageReopensTerminalTask() throws {
    let completedAt = Date.now
    let task = TaskSnapshot(
        id: "session-1",
        source: .codexDesktop,
        projectName: "AgentGrid",
        lifecycle: .succeeded,
        updatedAt: completedAt,
        completedAt: completedAt,
        isUnread: true
    )
    let line = try JSONSerialization.data(withJSONObject: [
        "type": "event_msg",
        "payload": [
            "type": "user_message",
            "message": "继续处理这个任务",
        ],
    ])
    let signal = try #require(CodexRolloutReader.signal(
        from: line,
        sessionID: "session-1",
        cwd: "/tmp/AgentGrid",
        now: completedAt.addingTimeInterval(1)
    ))
    var catalog = TaskCatalog(restoring: [task])

    catalog.accept(.rollout([signal]))
    let updated = try #require(catalog.projection().tasks.first)

    #expect(updated.lifecycle == .running)
    #expect(updated.completedAt == nil)
    #expect(updated.userPrompt == "继续处理这个任务")
}

@Test("Rollout 后续运行信号清除观察型等待状态")
func runningRolloutClearsObservedRequest() {
    let waitingAt = Date(timeIntervalSince1970: 4_000)
    let waiting = CodexRolloutSignal(
        sessionID: "session-1",
        cwd: "/tmp/AgentGrid",
        lifecycle: .waitingAnswer,
        activity: .thinking,
        requestKind: .question,
        summary: "是否继续？",
        timestamp: waitingAt
    )
    let resumed = CodexRolloutSignal(
        sessionID: "session-1",
        cwd: "/tmp/AgentGrid",
        lifecycle: .running,
        activity: .thinking,
        timestamp: waitingAt.addingTimeInterval(1)
    )
    var catalog = TaskCatalog()

    catalog.accept(.rollout([waiting]))
    #expect(catalog.projection().tasks[0].lifecycle == .waitingAnswer)
    #expect(catalog.projection().pendingRequests.count == 1)

    catalog.accept(.rollout([resumed]))
    #expect(catalog.projection().tasks[0].lifecycle == .running)
    #expect(catalog.projection().pendingRequests.isEmpty)
}

@Test("子代理变化与父 Task 活动在同一 Revision 中提交")
func subagentAndParentActivityCommitTogether() {
    let now = Date(timeIntervalSince1970: 5_000)
    let signal = CodexRolloutSignal(
        sessionID: "parent",
        cwd: "/tmp/AgentGrid",
        lifecycle: .running,
        activity: .editing,
        latestStep: "修改 TaskCatalog",
        subagentID: "child",
        subagentPath: "/root/catalog_tests",
        timestamp: now
    )
    var catalog = TaskCatalog()

    catalog.accept(.rollout([signal]))
    let task = catalog.projection().tasks[0]

    #expect(task.activity == .delegating)
    #expect(task.subagents.count == 1)
    #expect(task.subagents[0].id == "child")
    #expect(task.subagents[0].latestStep == "修改 TaskCatalog")
}

private final class RecordingPermissionResolver:
    CodexPermissionResolving,
    @unchecked Sendable
{
    struct Decision: Equatable {
        var sessionID: String
        var decision: CodexPermissionDecision
    }

    private(set) var decisions: [Decision] = []
    private let shouldFail: Bool

    init(shouldFail: Bool = false) {
        self.shouldFail = shouldFail
    }

    func resolve(
        sessionID: String,
        decision: CodexPermissionDecision
    ) throws {
        decisions.append(.init(sessionID: sessionID, decision: decision))
        if shouldFail {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
