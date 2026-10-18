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

@Test("失去会话文件的旧 Codex 运行任务会结束并按现有保留期清理")
func orphanedCodexTasksAreReconciledBySessionID() {
    let now = Date(timeIntervalSince1970: 20_000)
    let sharedTitle = "memories · Memory Writing Agent"
    let orphan = TaskSnapshot(
        id: "orphan-session",
        source: .codexDesktop,
        projectName: "memories",
        title: sharedTitle,
        lifecycle: .running,
        activity: .thinking,
        startedAt: now.addingTimeInterval(-10_000),
        updatedAt: now.addingTimeInterval(-4_000)
    )
    let live = TaskSnapshot(
        id: "live-session",
        source: .codexDesktop,
        projectName: "memories",
        title: sharedTitle,
        lifecycle: .running,
        activity: .thinking,
        startedAt: now.addingTimeInterval(-10_000),
        updatedAt: now.addingTimeInterval(-4_000)
    )
    var catalog = TaskCatalog(restoring: [orphan, live])

    let changed = catalog.reconcileCodexSessions(
        existingSessionIDs: ["live-session"],
        now: now
    )
    let tasks = catalog.projection().tasks

    #expect(changed)
    #expect(tasks.map(\.id) == ["live-session"])
    #expect(tasks[0].title == sharedTitle)
    #expect(tasks[0].lifecycle == .running)
}

@Test("会话清理保留缓冲期、等待状态、Claude 与仍有文件的任务")
func codexSessionReconciliationProtectsValidTasks() {
    let now = Date(timeIntervalSince1970: 30_000)
    let old = now.addingTimeInterval(-2_000)
    let tasks = [
        TaskSnapshot(
            id: "fresh-codex",
            source: .codexDesktop,
            projectName: "fresh",
            lifecycle: .running,
            updatedAt: now.addingTimeInterval(-599)
        ),
        TaskSnapshot(
            id: "approval",
            source: .codexDesktop,
            projectName: "approval",
            lifecycle: .waitingApproval,
            updatedAt: old
        ),
        TaskSnapshot(
            id: "answer",
            source: .codexCLI,
            projectName: "answer",
            lifecycle: .waitingAnswer,
            updatedAt: old
        ),
        TaskSnapshot(
            id: "live-codex",
            source: .codexCLI,
            projectName: "live",
            lifecycle: .running,
            updatedAt: old
        ),
        TaskSnapshot(
            id: "claude",
            source: .claudeCode,
            projectName: "claude",
            lifecycle: .running,
            updatedAt: old
        ),
    ]
    var catalog = TaskCatalog(
        restoring: tasks,
        pendingRequests: [
            PendingRequest(taskID: "approval", kind: .approval, summary: nil),
            PendingRequest(taskID: "answer", kind: .question, summary: nil),
        ]
    )

    let changed = catalog.reconcileCodexSessions(
        existingSessionIDs: ["live-codex"],
        now: now
    )

    #expect(!changed)
    #expect(Set(catalog.projection().tasks.map(\.id)) == Set(tasks.map(\.id)))
    #expect(catalog.projection().tasks.allSatisfy { !$0.isTerminal })
    #expect(catalog.projection().pendingRequests.count == 2)
}

@Test("较新的孤立任务先标记中断并沿用最后活动时间")
func recentOrphanUsesLastActivityForTerminalRetention() throws {
    let now = Date(timeIntervalSince1970: 40_000)
    let updatedAt = now.addingTimeInterval(-900)
    let task = TaskSnapshot(
        id: "recent-orphan",
        source: .codexCLI,
        projectName: "AgentPager",
        lifecycle: .starting,
        activity: .thinking,
        updatedAt: updatedAt
    )
    var catalog = TaskCatalog(restoring: [task])

    let changed = catalog.reconcileCodexSessions(
        existingSessionIDs: [],
        now: now
    )
    let interrupted = try #require(catalog.projection().tasks.first)

    #expect(changed)
    #expect(interrupted.lifecycle == .interrupted)
    #expect(interrupted.activity == nil)
    #expect(interrupted.completedAt == updatedAt)
    #expect(interrupted.isUnread)
}

@Test("Claude 会话核对会收敛启动、完成与失活任务")
func claudeSessionReconciliationConvergesLifecycle() throws {
    let now = Date(timeIntervalSince1970: 50_000)
    let old = now.addingTimeInterval(-700)
    let tasks = [
        TaskSnapshot(
            id: "starting-timeout",
            source: .claudeCode,
            projectName: "Claude",
            lifecycle: .starting,
            activity: .thinking,
            startedAt: old,
            updatedAt: old
        ),
        TaskSnapshot(
            id: "starting-open",
            source: .claudeCode,
            projectName: "Claude",
            lifecycle: .starting,
            activity: .thinking,
            startedAt: old,
            updatedAt: now.addingTimeInterval(-130)
        ),
        TaskSnapshot(
            id: "stopped",
            source: .claudeCode,
            projectName: "Claude",
            lifecycle: .running,
            activity: .thinking,
            startedAt: old,
            updatedAt: now.addingTimeInterval(-2)
        ),
        TaskSnapshot(
            id: "stale",
            source: .claudeCode,
            projectName: "Claude",
            lifecycle: .running,
            activity: .thinking,
            startedAt: old,
            updatedAt: old
        ),
    ]
    let stoppedAt = now.addingTimeInterval(-5)
    var catalog = TaskCatalog(restoring: tasks)

    let changed = catalog.reconcileClaudeSessions(
        evidenceBySessionID: [
            "starting-open": ClaudeTranscriptEvidence(
                sessionID: "starting-open",
                modificationDate: now,
                lastActivityAt: now,
                completedAt: nil,
                hasOpenTurn: true
            ),
            "stopped": ClaudeTranscriptEvidence(
                sessionID: "stopped",
                modificationDate: now,
                lastActivityAt: stoppedAt,
                completedAt: stoppedAt,
                hasOpenTurn: false
            ),
        ],
        now: now
    )

    #expect(changed)
    let byID = Dictionary(uniqueKeysWithValues: catalog.projection().tasks.map { ($0.id, $0) })
    #expect(byID["starting-timeout"]?.lifecycle == .offline)
    #expect(byID["starting-open"]?.lifecycle == .running)
    #expect(byID["stopped"]?.lifecycle == .succeeded)
    #expect(byID["stopped"]?.completedAt == stoppedAt)
    #expect(byID["stale"]?.lifecycle == .interrupted)
}

@Test("Claude 等待状态不会被普通存活核对清除")
func claudeSessionReconciliationPreservesWaitingTasks() {
    let now = Date(timeIntervalSince1970: 60_000)
    let waiting = TaskSnapshot(
        id: "waiting",
        source: .claudeCode,
        projectName: "Claude",
        lifecycle: .waitingApproval,
        activity: .executing,
        updatedAt: now.addingTimeInterval(-10_000),
        capabilities: [.approve, .deny]
    )
    var catalog = TaskCatalog(
        restoring: [waiting],
        pendingRequests: [PendingRequest(taskID: "waiting", kind: .approval, summary: nil)]
    )

    let changed = catalog.reconcileClaudeSessions(
        evidenceBySessionID: [:],
        now: now
    )

    #expect(!changed)
    #expect(catalog.projection().tasks.first?.lifecycle == .waitingApproval)
    #expect(catalog.projection().pendingRequests.count == 1)
}

@Test("审批连接超时后清除待办并结束等待状态")
func pendingApprovalExpirationInterruptsTask() throws {
    let now = Date(timeIntervalSince1970: 70_000)
    let waiting = TaskSnapshot(
        id: "waiting",
        source: .claudeCode,
        projectName: "Claude",
        lifecycle: .waitingApproval,
        activity: .executing,
        startedAt: now.addingTimeInterval(-60),
        updatedAt: now.addingTimeInterval(-1),
        capabilities: [.approve, .deny]
    )
    var catalog = TaskCatalog(
        restoring: [waiting],
        pendingRequests: [PendingRequest(taskID: "waiting", kind: .approval, summary: nil)]
    )

    let changed = catalog.expirePendingRequest(sessionID: "waiting", now: now)
    #expect(changed)
    let task = try #require(catalog.projection().tasks.first)
    #expect(task.lifecycle == .interrupted)
    #expect(task.completedAt == now)
    #expect(task.capabilities.isEmpty)
    #expect(catalog.projection().pendingRequests.isEmpty)
}

@Test("A stale Codex rollout without a live writer is cleaned even while its file exists")
func codexSessionReconciliationCleansAbandonedRollout() {
    let now = Date(timeIntervalSince1970: 80_000)
    let old = now.addingTimeInterval(-4_000)
    let abandoned = TaskSnapshot(
        id: "abandoned",
        source: .codexCLI,
        projectName: "方案",
        lifecycle: .running,
        activity: .executing,
        startedAt: old,
        updatedAt: old
    )
    var live = abandoned
    live.id = "live"
    var catalog = TaskCatalog(restoring: [abandoned, live])

    let changed = catalog.reconcileCodexSessions(
        existingSessionIDs: ["abandoned", "live"],
        liveSessionIDs: ["live"],
        now: now
    )

    #expect(changed)
    #expect(catalog.projection().tasks.map(\.id) == ["live"])
    #expect(catalog.projection().tasks.first?.lifecycle == .running)
}

@Test("Writer reconciliation protects fresh tasks, waiting states and unknown liveness")
func codexWriterReconciliationProtectsActiveAndWaitingTasks() {
    let now = Date(timeIntervalSince1970: 90_000)
    let fresh = TaskSnapshot(
        id: "fresh",
        source: .codexDesktop,
        projectName: "AgentPager",
        lifecycle: .running,
        updatedAt: now.addingTimeInterval(-599)
    )
    var approval = fresh
    approval.id = "approval"
    approval.lifecycle = .waitingApproval
    approval.updatedAt = now.addingTimeInterval(-4_000)
    var answer = approval
    answer.id = "answer"
    answer.lifecycle = .waitingAnswer
    var catalog = TaskCatalog(restoring: [fresh, approval, answer])

    let changed = catalog.reconcileCodexSessions(
        existingSessionIDs: ["fresh", "approval", "answer"],
        liveSessionIDs: [],
        now: now
    )
    #expect(!changed)
    #expect(catalog.projection().tasks.count == 3)

    let probeFailed = catalog.reconcileCodexSessions(
        existingSessionIDs: ["fresh", "approval", "answer"],
        liveSessionIDs: nil,
        now: now.addingTimeInterval(1_000)
    )
    #expect(!probeFailed)
    #expect(catalog.projection().tasks.count == 3)
}

@Test("A new real Codex event restarts a session after its abandoned turn was reconciled")
func codexSessionCanResumeAfterWriterCleanup() {
    let now = Date(timeIntervalSince1970: 100_000)
    let old = now.addingTimeInterval(-900)
    let task = TaskSnapshot(
        id: "resumed",
        source: .codexCLI,
        projectName: "AgentPager",
        lifecycle: .running,
        updatedAt: old
    )
    var catalog = TaskCatalog(restoring: [task])
    _ = catalog.reconcileCodexSessions(
        existingSessionIDs: ["resumed"],
        liveSessionIDs: [],
        now: now
    )
    #expect(catalog.projection().tasks.first?.lifecycle == .interrupted)

    _ = catalog.accept(.hook(CodexHookPayload(
        cwd: "/tmp/AgentPager",
        hookEventName: .userPromptSubmit,
        sessionID: "resumed",
        prompt: "继续"
    ), receivedAt: now.addingTimeInterval(1)))
    #expect(catalog.projection().tasks.first?.lifecycle == .running)
    #expect(catalog.projection().tasks.first?.completedAt == nil)
}

@Test("Claude 上一轮的完成证据不能结束新一轮")
func claudeOldStopCannotFinishNewTurn() {
    let now = Date(timeIntervalSince1970: 110_000)
    let task = TaskSnapshot(
        id: "next-turn",
        source: .claudeCode,
        projectName: "Claude",
        lifecycle: .running,
        startedAt: now,
        updatedAt: now
    )
    var catalog = TaskCatalog(restoring: [task])
    let changed = catalog.reconcileClaudeSessions(
        evidenceBySessionID: ["next-turn": ClaudeTranscriptEvidence(
            sessionID: "next-turn",
            modificationDate: now,
            lastActivityAt: now.addingTimeInterval(-5),
            completedAt: now.addingTimeInterval(-5),
            hasOpenTurn: false
        )],
        now: now
    )
    #expect(!changed)
    #expect(catalog.projection().tasks.first?.lifecycle == .running)
}

@Test("Claude 长时间执行不会仅因日志安静而被标记中断")
func claudeLongRunningToolIsNotTimedOutBySilence() {
    let now = Date(timeIntervalSince1970: 120_000)
    let old = now.addingTimeInterval(-4_000)
    let task = TaskSnapshot(
        id: "long-command",
        source: .claudeCode,
        projectName: "Claude",
        lifecycle: .running,
        activity: .executing,
        startedAt: old,
        updatedAt: old
    )
    var catalog = TaskCatalog(restoring: [task])
    let changed = catalog.reconcileClaudeSessions(
        evidenceBySessionID: ["long-command": ClaudeTranscriptEvidence(
            sessionID: "long-command",
            modificationDate: old,
            lastActivityAt: old,
            completedAt: nil,
            hasOpenTurn: true
        )],
        now: now
    )
    #expect(!changed)
    #expect(catalog.projection().tasks.first?.lifecycle == .running)
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
