import Foundation
import Testing
@testable import AgentGridCore

@Test("Claude UserPromptSubmit 设置运行态与用户提示")
func claudeUserPromptSubmitRuns() {
    let hook = ClaudeHookPayload(
        cwd: "/tmp/agentpager",
        hookEventName: "UserPromptSubmit",
        sessionID: "claude-1",
        prompt: "重构 Hook 桥接"
    )
    let task = ClaudeEventReducer.task(from: hook, existing: nil)
    #expect(task.source == .claudeCode)
    #expect(task.lifecycle == .running)
    #expect(task.userPrompt == "重构 Hook 桥接")
    #expect(task.title.contains("重构 Hook 桥接"))
}

@Test("Claude PermissionRequest 进入等待批准并授予批准/拒绝能力")
func claudePermissionRequestWaitsForApproval() {
    let hook = ClaudeHookPayload(
        cwd: "/tmp/agentpager",
        hookEventName: "PermissionRequest",
        sessionID: "claude-1",
        toolName: "Bash",
        toolInput: .object(["command": .string("rm -rf /tmp/x")])
    )
    let task = ClaudeEventReducer.task(from: hook, existing: nil)
    #expect(task.lifecycle == .waitingApproval)
    #expect(task.capabilities == [.approve, .deny])
    #expect(task.latestStep?.contains("rm -rf /tmp/x") == true)
}

@Test("Claude Stop 标记完成且未读")
func claudeStopSucceeds() {
    let running = ClaudeEventReducer.task(
        from: ClaudeHookPayload(
            cwd: "/tmp/agentpager",
            hookEventName: "UserPromptSubmit",
            sessionID: "claude-1"
        ),
        existing: nil
    )
    let stopped = ClaudeEventReducer.task(
        from: ClaudeHookPayload(
            cwd: "/tmp/agentpager",
            hookEventName: "Stop",
            sessionID: "claude-1"
        ),
        existing: running
    )
    #expect(stopped.lifecycle == .succeeded)
    #expect(stopped.isUnread == true)
    #expect(stopped.completedAt != nil)
}

@Test("TaskCatalog 接受 Claude 权限请求并登记 PendingRequest")
func taskCatalogAcceptsClaudePermissionRequest() throws {
    var catalog = TaskCatalog()
    let accepted = catalog.accept(.claudeHook(ClaudeHookPayload(
        cwd: "/tmp/agentpager",
        hookEventName: "PermissionRequest",
        sessionID: "claude-1",
        toolName: "Bash",
        toolInput: .object(["command": .string("echo hi")])
    )))
    #expect(accepted)
    let projection = catalog.projection()
    let task = try #require(projection.tasks.first { $0.id == "claude-1" })
    #expect(task.source == .claudeCode)
    #expect(task.lifecycle == .waitingApproval)
    #expect(projection.pendingRequests.count == 1)
    #expect(projection.pendingRequests.first?.kind == .approval)
}

@Test("Claude 权限通知不会覆盖待审批状态")
func claudePermissionNotificationPreservesApproval() throws {
    var catalog = TaskCatalog()
    _ = catalog.accept(.claudeHook(ClaudeHookPayload(
        cwd: "/tmp/agentpager",
        hookEventName: "PermissionRequest",
        sessionID: "claude-1",
        toolName: "Bash",
        toolInput: .object(["command": .string("echo hi")])
    )))

    _ = catalog.accept(.claudeHook(ClaudeHookPayload(
        cwd: "/tmp/agentpager",
        hookEventName: "Notification",
        sessionID: "claude-1",
        message: "Claude 需要批准 Bash",
        notificationType: "permission_prompt"
    )))

    let projection = catalog.projection()
    let task = try #require(projection.tasks.first { $0.id == "claude-1" })
    #expect(task.lifecycle == .waitingApproval)
    #expect(task.capabilities == [.approve, .deny])
    #expect(projection.pendingRequests.count == 1)
    #expect(projection.pendingRequests.first?.kind == .approval)
}

@Test("Claude 通知按类型区分状态通知与等待输入")
func claudeNotificationsFollowType() throws {
    var catalog = TaskCatalog()
    _ = catalog.accept(.claudeHook(ClaudeHookPayload(
        cwd: "/tmp/agentpager",
        hookEventName: "UserPromptSubmit",
        sessionID: "claude-1",
        prompt: "继续处理"
    )))

    _ = catalog.accept(.claudeHook(ClaudeHookPayload(
        cwd: "/tmp/agentpager",
        hookEventName: "Notification",
        sessionID: "claude-1",
        message: "认证成功",
        notificationType: "auth_success"
    )))

    var projection = catalog.projection()
    var task = try #require(projection.tasks.first { $0.id == "claude-1" })
    #expect(task.lifecycle == .running)
    #expect(projection.pendingRequests.isEmpty)

    _ = catalog.accept(.claudeHook(ClaudeHookPayload(
        cwd: "/tmp/agentpager",
        hookEventName: "Notification",
        sessionID: "claude-1",
        message: "Claude 正在等待输入",
        notificationType: "idle_prompt"
    )))

    projection = catalog.projection()
    task = try #require(projection.tasks.first { $0.id == "claude-1" })
    #expect(task.lifecycle == .waitingAnswer)
    #expect(projection.pendingRequests.first?.kind == .question)
}

@Test("Claude 状态通知保留终态完成时间")
func claudeStatusNotificationPreservesTerminalCompletion() throws {
    let stoppedAt = Date(timeIntervalSince1970: 100)
    var catalog = TaskCatalog()
    _ = catalog.accept(.claudeHook(
        ClaudeHookPayload(
            cwd: "/tmp/agentpager",
            hookEventName: "Stop",
            sessionID: "claude-1"
        ),
        receivedAt: stoppedAt
    ))

    _ = catalog.accept(.claudeHook(
        ClaudeHookPayload(
            cwd: "/tmp/agentpager",
            hookEventName: "Notification",
            sessionID: "claude-1",
            message: "认证成功",
            notificationType: "auth_success"
        ),
        receivedAt: stoppedAt.addingTimeInterval(1)
    ))

    let task = try #require(catalog.projection().tasks.first { $0.id == "claude-1" })
    #expect(task.lifecycle == .succeeded)
    #expect(task.completedAt == stoppedAt)
}

@Test("TaskCatalog 在 Claude Stop 后清除待办权限")
func taskCatalogClearsClaudePendingRequestOnStop() {
    var catalog = TaskCatalog()
    _ = catalog.accept(.claudeHook(ClaudeHookPayload(
        cwd: "/tmp/agentpager",
        hookEventName: "PermissionRequest",
        sessionID: "claude-1"
    )))
    catalog.accept(.claudeHook(ClaudeHookPayload(
        cwd: "/tmp/agentpager",
        hookEventName: "Stop",
        sessionID: "claude-1"
    )))
    #expect(catalog.projection().pendingRequests.isEmpty)
}

@Test("未知 Claude 事件不改变生命周期，只刷新时间戳")
func claudeUnknownEventLeavesLifecycle() {
    let running = ClaudeEventReducer.task(
        from: ClaudeHookPayload(
            cwd: "/tmp/agentpager",
            hookEventName: "UserPromptSubmit",
            sessionID: "claude-1"
        ),
        existing: nil
    )
    let after = ClaudeEventReducer.task(
        from: ClaudeHookPayload(
            cwd: "/tmp/agentpager",
            hookEventName: "FutureEvent",
            sessionID: "claude-1"
        ),
        existing: running
    )
    #expect(after.lifecycle == .running)
}

@Test("Claude SubagentStart 建立子代理，SubagentStop 标记完成")
func claudeSubagentLifecycle() {
    var task = ClaudeEventReducer.task(
        from: ClaudeHookPayload(
            cwd: "/tmp/agentpager",
            hookEventName: "UserPromptSubmit",
            sessionID: "claude-1"
        ),
        existing: nil
    )
    task = ClaudeEventReducer.task(
        from: ClaudeHookPayload(
            cwd: "/tmp/agentpager",
            hookEventName: "SubagentStart",
            sessionID: "claude-1",
            agentID: "sub-1",
            agentType: "general-purpose",
            taskDescription: "调研 Hook 协议"
        ),
        existing: task
    )
    #expect(task.subagents.count == 1)
    #expect(task.subagents.first?.id == "sub-1")
    #expect(task.subagents.first?.lifecycle == .running)
    #expect(task.subagents.first?.latestStep == "调研 Hook 协议")
    #expect(task.activity == .delegating)

    task = ClaudeEventReducer.task(
        from: ClaudeHookPayload(
            cwd: "/tmp/agentpager",
            hookEventName: "SubagentStop",
            sessionID: "claude-1",
            agentID: "sub-1",
            agentType: "general-purpose"
        ),
        existing: task
    )
    #expect(task.subagents.first?.lifecycle == .succeeded)
    // 全部子代理终态后，父任务不再标记为 delegating。
    #expect(task.activity == .thinking)
}

@Test("Claude 终态不被同轮迟到工具事件复活")
func claudeTerminalStateRejectsLateEvents() {
    let stoppedAt = Date(timeIntervalSince1970: 1_000)
    var task = ClaudeEventReducer.task(
        from: ClaudeHookPayload(
            cwd: "/tmp/agentpager",
            hookEventName: "UserPromptSubmit",
            sessionID: "claude-desktop",
            prompt: "修复状态"
        ),
        existing: nil,
        now: stoppedAt.addingTimeInterval(-10)
    )
    task = ClaudeEventReducer.task(
        from: ClaudeHookPayload(
            cwd: "/tmp/agentpager",
            hookEventName: "Stop",
            sessionID: "claude-desktop"
        ),
        existing: task,
        now: stoppedAt
    )
    let completed = task

    for event in ["PostToolUse", "PreToolUse", "PreCompact", "SubagentStop", "StopFailure"] {
        task = ClaudeEventReducer.task(
            from: ClaudeHookPayload(
                cwd: "/tmp/agentpager",
                hookEventName: event,
                sessionID: "claude-desktop",
                toolName: "Bash",
                agentID: "late-subagent"
            ),
            existing: task,
            now: stoppedAt.addingTimeInterval(2)
        )
        #expect(task == completed)
    }
}

@Test("Claude 同一提示也可开启下一轮，文本相同不代表重放")
func claudeRepeatedPromptStartsNewTurn() {
    let stoppedAt = Date(timeIntervalSince1970: 2_000)
    let original = ClaudeHookPayload(
        cwd: "/tmp/agentpager",
        hookEventName: "UserPromptSubmit",
        sessionID: "claude-desktop",
        prompt: "第一轮"
    )
    var task = ClaudeEventReducer.task(
        from: original,
        existing: nil,
        now: stoppedAt.addingTimeInterval(-10)
    )
    task = ClaudeEventReducer.task(
        from: ClaudeHookPayload(
            cwd: "/tmp/agentpager",
            hookEventName: "Stop",
            sessionID: "claude-desktop"
        ),
        existing: task,
        now: stoppedAt
    )

    let replayed = ClaudeEventReducer.task(
        from: original,
        existing: task,
        now: stoppedAt.addingTimeInterval(2)
    )
    #expect(replayed.lifecycle == .running)
    #expect(replayed.completedAt == nil)
    #expect(replayed.startedAt == stoppedAt.addingTimeInterval(2))

    let next = ClaudeEventReducer.task(
        from: ClaudeHookPayload(
            cwd: "/tmp/agentpager",
            hookEventName: "UserPromptSubmit",
            sessionID: "claude-desktop",
            prompt: "第二轮"
        ),
        existing: replayed,
        now: stoppedAt.addingTimeInterval(3)
    )
    #expect(next.lifecycle == .running)
    #expect(next.userPrompt == "第二轮")
    #expect(next.completedAt == nil)
    #expect(!next.isUnread)
}

@Test("Claude 预热 SessionStart 和压缩事件不覆盖现有运行或等待状态")
func claudeWarmupAndToolReceiptsPreserveState() {
    let now = Date(timeIntervalSince1970: 3_000)
    let running = TaskSnapshot(
        id: "claude-desktop",
        source: .claudeCode,
        projectName: "agentpager",
        lifecycle: .running,
        activity: .editing,
        startedAt: now.addingTimeInterval(-20),
        updatedAt: now.addingTimeInterval(-5)
    )
    let afterWarmup = ClaudeEventReducer.task(
        from: ClaudeHookPayload(
            cwd: "/tmp/agentpager",
            hookEventName: "SessionStart",
            sessionID: "claude-desktop",
            source: "resume"
        ),
        existing: running,
        now: now
    )
    #expect(afterWarmup.lifecycle == .running)
    #expect(afterWarmup.activity == .editing)

    var waiting = afterWarmup
    waiting.lifecycle = .waitingApproval
    waiting.capabilities = [.approve, .deny]
    let afterReceipt = ClaudeEventReducer.task(
        from: ClaudeHookPayload(
            cwd: "/tmp/agentpager",
            hookEventName: "PreCompact",
            sessionID: "claude-desktop"
        ),
        existing: waiting,
        now: now.addingTimeInterval(1)
    )
    #expect(afterReceipt.lifecycle == .waitingApproval)
    #expect(afterReceipt.capabilities == [.approve, .deny])
}

@Test("Claude 在电脑上批准后工具结果恢复运行并清除手机待办")
func claudeLocalApprovalResumesTask() {
    let now = Date(timeIntervalSince1970: 4_000)
    var catalog = TaskCatalog()
    _ = catalog.accept(.claudeHook(ClaudeHookPayload(
        cwd: "/tmp/agentpager",
        hookEventName: "PermissionRequest",
        sessionID: "local-approval",
        toolName: "Bash",
        toolUseID: "tool-1"
    ), receivedAt: now))
    #expect(catalog.projection().tasks.first?.lifecycle == .waitingApproval)

    _ = catalog.accept(.claudeHook(ClaudeHookPayload(
        cwd: "/tmp/agentpager",
        hookEventName: "PostToolUse",
        sessionID: "local-approval",
        toolName: "Bash",
        toolUseID: "tool-1"
    ), receivedAt: now.addingTimeInterval(1)))
    #expect(catalog.projection().tasks.first?.lifecycle == .running)
    #expect(catalog.projection().tasks.first?.capabilities.isEmpty == true)
    #expect(catalog.projection().pendingRequests.isEmpty)
}

@Test("Claude 终态后的迟到通知不会创建幽灵待办")
func claudeLateRequestsDoNotCreatePendingState() {
    let now = Date(timeIntervalSince1970: 5_000)
    var catalog = TaskCatalog()
    _ = catalog.accept(.claudeHook(ClaudeHookPayload(
        cwd: "/tmp/agentpager",
        hookEventName: "Stop",
        sessionID: "late-request"
    ), receivedAt: now))
    for event in ["PermissionRequest", "Notification"] {
        _ = catalog.accept(.claudeHook(ClaudeHookPayload(
            cwd: "/tmp/agentpager",
            hookEventName: event,
            sessionID: "late-request",
            notificationType: "idle_prompt"
        ), receivedAt: now.addingTimeInterval(1)))
        #expect(catalog.projection().tasks.first?.lifecycle == .succeeded)
        #expect(catalog.projection().pendingRequests.isEmpty)
    }
}

@Test("Claude 原生工具区分读取、搜索、编辑、测试与普通执行")
func claudeNativeToolActivities() {
    let cases: [(String, String?, AgentActivity)] = [
        ("Read", nil, .reading),
        ("Glob", nil, .searching),
        ("Grep", nil, .searching),
        ("Edit", nil, .editing),
        ("Write", nil, .editing),
        ("Bash", "python3 -m unittest", .testing),
        ("Bash", "npm test", .testing),
        ("Bash", "echo done", .executing),
        ("Agent", nil, .delegating),
    ]
    for (name, command, expected) in cases {
        let hook = ClaudeHookPayload(
            cwd: "/tmp/AgentPager",
            hookEventName: "PreToolUse",
            sessionID: "tool-test",
            toolName: name,
            toolInput: command.map { .object(["command": .string($0)]) }
        )
        let task = ClaudeEventReducer.task(from: hook, existing: nil)
        #expect(task.lifecycle == .running)
        #expect(task.activity == expected)
    }
}

@Test("Claude AskUserQuestion 立即显示等待回答，工具结果恢复运行")
func claudeQuestionToolHasWaitingLifecycle() {
    let now = Date(timeIntervalSince1970: 6_000)
    var catalog = TaskCatalog()
    _ = catalog.accept(.claudeHook(ClaudeHookPayload(
        cwd: "/tmp/AgentPager",
        hookEventName: "PreToolUse",
        sessionID: "question-tool",
        toolName: "AskUserQuestion",
        toolInput: .object(["questions": .array([
            .object(["question": .string("Which option?")]),
        ])])
    ), receivedAt: now))
    #expect(catalog.projection().tasks.first?.lifecycle == .waitingAnswer)
    #expect(catalog.projection().tasks.first?.capabilities.isEmpty == true)
    #expect(catalog.projection().pendingRequests.first?.kind == .question)
    #expect(catalog.projection().pendingRequests.first?.summary == "Which option?")

    _ = catalog.accept(.claudeHook(ClaudeHookPayload(
        cwd: "/tmp/AgentPager",
        hookEventName: "PostToolUse",
        sessionID: "question-tool",
        toolName: "AskUserQuestion"
    ), receivedAt: now.addingTimeInterval(1)))
    #expect(catalog.projection().tasks.first?.lifecycle == .running)
    #expect(catalog.projection().pendingRequests.isEmpty)
}

@Test("Claude PermissionDenied 只是单次工具被拒，本轮继续运行直到 Stop")
func claudePermissionDeniedKeepsTurnRunning() {
    let start = Date(timeIntervalSince1970: 4_000)
    var task = ClaudeEventReducer.task(
        from: ClaudeHookPayload(
            cwd: "/tmp/agentpager",
            hookEventName: "UserPromptSubmit",
            sessionID: "claude-auto",
            prompt: "测试"
        ),
        existing: nil,
        now: start
    )
    task = ClaudeEventReducer.task(
        from: ClaudeHookPayload(
            cwd: "/tmp/agentpager",
            hookEventName: "PermissionDenied",
            sessionID: "claude-auto",
            toolName: "Bash"
        ),
        existing: task,
        now: start.addingTimeInterval(5)
    )
    #expect(task.lifecycle == .running)
    #expect(task.completedAt == nil)

    task = ClaudeEventReducer.task(
        from: ClaudeHookPayload(
            cwd: "/tmp/agentpager",
            hookEventName: "PreToolUse",
            sessionID: "claude-auto",
            toolName: "Read",
            toolInput: .object(["file_path": .string("/tmp/a")])
        ),
        existing: task,
        now: start.addingTimeInterval(8)
    )
    #expect(task.lifecycle == .running)
    #expect(task.latestStep?.contains("/tmp/a") == true)

    task = ClaudeEventReducer.task(
        from: ClaudeHookPayload(
            cwd: "/tmp/agentpager",
            hookEventName: "Stop",
            sessionID: "claude-auto"
        ),
        existing: task,
        now: start.addingTimeInterval(20)
    )
    #expect(task.lifecycle == .succeeded)
}
