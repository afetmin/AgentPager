import Foundation

public struct TaskCatalogProjection: Equatable, Sendable {
    public var revision: UInt64
    public var tasks: [TaskSnapshot]
    public var focusedTaskID: String?
    public var pendingRequests: [PendingRequest]

    public init(
        revision: UInt64,
        tasks: [TaskSnapshot],
        focusedTaskID: String?,
        pendingRequests: [PendingRequest]
    ) {
        self.revision = revision
        self.tasks = tasks
        self.focusedTaskID = focusedTaskID
        self.pendingRequests = pendingRequests
    }
}

public struct AuthorizedTaskControl: Equatable, Sendable {
    public var requestID: UUID
    public var taskID: String
    public var action: ControlAction
    public var value: String?

    public init(
        requestID: UUID,
        taskID: String,
        action: ControlAction,
        value: String? = nil
    ) {
        self.requestID = requestID
        self.taskID = taskID
        self.action = action
        self.value = value
    }
}

public struct TaskControlReceipt: Equatable, Sendable {
    public var requestID: UUID
    public var result: ControlResult
    public var reason: String?
    public var committedRevision: UInt64?

    public init(
        requestID: UUID,
        result: ControlResult,
        reason: String? = nil,
        committedRevision: UInt64? = nil
    ) {
        self.requestID = requestID
        self.result = result
        self.reason = reason
        self.committedRevision = committedRevision
    }
}

public protocol CodexPermissionResolving: Sendable {
    func resolve(
        sessionID: String,
        decision: CodexPermissionDecision
    ) throws
}

public enum TaskCatalogInput: Sendable {
    case hook(CodexHookPayload, receivedAt: Date = .now)
    case claudeHook(ClaudeHookPayload, receivedAt: Date = .now)
    case rollout([CodexRolloutSignal])
    case synthetic(TaskSnapshot)
}

public struct TaskCatalog: Sendable {
    private var store: TaskStore
    private var requestsByTaskID: [String: PendingRequest]
    private(set) public var revision: UInt64

    public init(
        restoring tasks: [TaskSnapshot] = [],
        pendingRequests: [PendingRequest] = []
    ) {
        store = TaskStore(tasks: tasks)
        requestsByTaskID = Dictionary(
            uniqueKeysWithValues: pendingRequests.map { ($0.taskID, $0) }
        )
        revision = 0
        normalizeRestoredState()
    }

    @discardableResult
    public mutating func accept(_ input: TaskCatalogInput) -> Bool {
        let previousTasks = store.tasks
        let previousRequests = requestsByTaskID

        switch input {
        case let .hook(hook, receivedAt):
            apply(hook, receivedAt: receivedAt)
        case let .claudeHook(hook, receivedAt):
            apply(hook, receivedAt: receivedAt)
        case let .rollout(signals):
            for signal in signals.sorted(by: Self.signalOrder) {
                apply(signal)
            }
        case let .synthetic(task):
            store.upsert(task)
        }

        normalize(now: latestUpdateDate ?? .now)
        return commitIfChanged(
            previousTasks: previousTasks,
            previousRequests: previousRequests
        )
    }

    public mutating func applyAvailableTitles(
        _ titlesByTaskID: [String: String]
    ) -> Bool {
        let previousTasks = store.tasks
        guard store.applyTitles(titlesByTaskID) else {
            return false
        }
        return commitIfChanged(
            previousTasks: previousTasks,
            previousRequests: requestsByTaskID
        )
    }

    @discardableResult
    public mutating func maintain(now: Date = .now) -> Bool {
        let previousTasks = store.tasks
        let previousRequests = requestsByTaskID

        normalize(now: now)

        return commitIfChanged(
            previousTasks: previousTasks,
            previousRequests: previousRequests
        )
    }

    @discardableResult
    public mutating func reconcileCodexSessions(
        existingSessionIDs: Set<String>,
        now: Date = .now,
        gracePeriod: TimeInterval = 10 * 60
    ) -> Bool {
        let previousTasks = store.tasks
        let previousRequests = requestsByTaskID

        _ = store.interruptOrphanedCodexTasks(
            existingSessionIDs: existingSessionIDs,
            now: now,
            gracePeriod: gracePeriod
        )
        normalize(now: now)

        return commitIfChanged(
            previousTasks: previousTasks,
            previousRequests: previousRequests
        )
    }

    public mutating func perform(
        _ control: AuthorizedTaskControl,
        permissionResolver: any CodexPermissionResolving,
        now: Date = .now
    ) -> TaskControlReceipt {
        guard let task = store.tasks.first(where: { $0.id == control.taskID }) else {
            return TaskControlReceipt(
                requestID: control.requestID,
                result: .stale,
                reason: "任务已结束或不存在"
            )
        }

        let previousTasks = store.tasks
        let previousRequests = requestsByTaskID
        var updated = task

        switch control.action {
        case .approve:
            guard updated.capabilities.contains(.approve),
                  requestsByTaskID[updated.id]?.kind == .approval else {
                return unsupported(control, reason: "当前任务不能批准")
            }
            do {
                try permissionResolver.resolve(sessionID: updated.id, decision: .allow)
            } catch {
                return TaskControlReceipt(
                    requestID: control.requestID,
                    result: .rejected,
                    reason: "批准请求发送失败：\(error.localizedDescription)"
                )
            }
            requestsByTaskID.removeValue(forKey: updated.id)
            updated.lifecycle = .running
            updated.activity = .thinking
            updated.completedAt = nil
            updated.capabilities = []
        case .deny:
            guard updated.capabilities.contains(.deny),
                  requestsByTaskID[updated.id]?.kind == .approval else {
                return unsupported(control, reason: "当前任务不能拒绝")
            }
            do {
                try permissionResolver.resolve(sessionID: updated.id, decision: .deny)
            } catch {
                return TaskControlReceipt(
                    requestID: control.requestID,
                    result: .rejected,
                    reason: "拒绝请求发送失败：\(error.localizedDescription)"
                )
            }
            requestsByTaskID.removeValue(forKey: updated.id)
            updated.lifecycle = .interrupted
            updated.activity = nil
            updated.completedAt = now
            updated.isUnread = true
            updated.capabilities = []
        case .mute:
            updated.isMuted.toggle()
        case .markRead:
            updated.isUnread = false
        case .pin:
            updated.isPinned.toggle()
        case .answer, .interrupt, .retry:
            return unsupported(control, reason: "当前 Codex 通道暂未提供稳定能力")
        }

        updated.updatedAt = max(updated.updatedAt, now)
        store.upsert(updated)
        _ = commitIfChanged(
            previousTasks: previousTasks,
            previousRequests: previousRequests
        )
        return TaskControlReceipt(
            requestID: control.requestID,
            result: .accepted,
            committedRevision: revision
        )
    }

    public func projection(
        focusedTaskIDOverride: String? = nil
    ) -> TaskCatalogProjection {
        TaskCatalogProjection(
            revision: revision,
            tasks: store.tasks.sorted { $0.updatedAt > $1.updatedAt },
            focusedTaskID: focusedTaskIDOverride ?? store.focusedTask()?.id,
            pendingRequests: requestsByTaskID.values.sorted {
                $0.taskID < $1.taskID
            }
        )
    }

    private mutating func normalizeRestoredState() {
        normalize(now: .now)
    }

    private mutating func normalize(now: Date) {
        store.purge(now: now)
        _ = store.purgeTerminalSubagents(now: now)
        let taskIDs = Set(store.tasks.map(\.id))
        requestsByTaskID = requestsByTaskID.filter { taskIDs.contains($0.key) }
    }

    private mutating func apply(
        _ hook: CodexHookPayload,
        receivedAt: Date
    ) {
        let existing = store.tasks.first { $0.id == hook.sessionID }
        let task = CodexEventReducer.task(
            from: hook,
            existing: existing,
            now: receivedAt
        )

        switch hook.hookEventName {
        case .permissionRequest:
            requestsByTaskID[hook.sessionID] = PendingRequest(
                taskID: hook.sessionID,
                kind: .approval,
                summary: hook.toolInput?.summary
            )
        case .stop:
            requestsByTaskID.removeValue(forKey: hook.sessionID)
        case .sessionStart, .userPromptSubmit, .preToolUse, .postToolUse:
            if task.lifecycle == .running {
                requestsByTaskID.removeValue(forKey: hook.sessionID)
            }
        }
        store.upsert(task)
    }

    private mutating func apply(
        _ hook: ClaudeHookPayload,
        receivedAt: Date
    ) {
        let existing = store.tasks.first { $0.id == hook.sessionID }
        let task = ClaudeEventReducer.task(
            from: hook,
            existing: existing,
            now: receivedAt
        )

        switch hook.event {
        case .permissionRequest:
            requestsByTaskID[hook.sessionID] = PendingRequest(
                taskID: hook.sessionID,
                kind: .approval,
                summary: ClaudeEventReducer.summary(from: hook.toolInput)
                    ?? hook.toolName
            )
        case .notification:
            if ClaudeEventReducer.isAnswerNotification(hook.notificationType) {
                requestsByTaskID[hook.sessionID] = PendingRequest(
                    taskID: hook.sessionID,
                    kind: .question,
                    summary: hook.title ?? hook.message
                )
            }
        case .stop, .sessionEnd, .permissionDenied:
            requestsByTaskID.removeValue(forKey: hook.sessionID)
        case .sessionStart, .userPromptSubmit, .preToolUse, .postToolUse,
             .postToolUseFailure, .preCompact, .subagentStart, .subagentStop,
             .stopFailure:
            if task.lifecycle == .running {
                requestsByTaskID.removeValue(forKey: hook.sessionID)
            }
        case nil:
            break
        }
        store.upsert(task)
    }

    private mutating func apply(_ signal: CodexRolloutSignal) {
        var task = store.tasks.first { $0.id == signal.sessionID }
            ?? TaskSnapshot(
                id: signal.sessionID,
                source: .codexCLI,
                projectName: URL(fileURLWithPath: signal.cwd).lastPathComponent,
                lifecycle: signal.lifecycle ?? .running,
                startedAt: signal.timestamp,
                updatedAt: signal.timestamp
            )

        if let subagentID = signal.subagentID {
            apply(signal, subagentID: subagentID, to: &task)
            store.upsert(task)
            return
        }

        let isCurrent = signal.timestamp >= task.updatedAt
        if let lifecycle = signal.lifecycle, isCurrent || task.lifecycle == .starting {
            // 时间较新的新一轮输入可以让已完成任务恢复运行；旧 rollout 已由 isCurrent 拦截。
            task.lifecycle = lifecycle
        }
        if let activity = signal.activity, isCurrent || task.activity == nil {
            task.activity = activity
        }
        if let prompt = signal.userPrompt, isCurrent || task.userPrompt == nil {
            task.userPrompt = prompt
            if task.title == task.projectName {
                task.title = CodexEventReducer.title(
                    projectName: task.projectName,
                    prompt: prompt
                )
            }
        }
        if let latestStep = signal.latestStep, isCurrent || task.latestStep == nil {
            task.latestStep = latestStep
        }
        if let tokenUsage = signal.tokenUsage,
           tokenUsage.total >= (task.tokenUsage?.total ?? 0) {
            task.tokenUsage = tokenUsage
        }

        task.updatedAt = max(task.updatedAt, signal.timestamp)
        if task.isTerminal {
            task.completedAt = max(task.completedAt ?? signal.timestamp, signal.timestamp)
            task.isUnread = true
        } else if isCurrent {
            task.completedAt = nil
        }

        if isCurrent {
            applyRequestState(signal, to: &task)
        }
        store.upsert(task)
    }

    private mutating func apply(
        _ signal: CodexRolloutSignal,
        subagentID: String,
        to task: inout TaskSnapshot
    ) {
        let path = signal.subagentPath ?? task.subagents
            .first(where: { $0.id == subagentID })?
            .path
            ?? "/root/subagent"
        var subagent = task.subagents.first { $0.id == subagentID }
            ?? SubagentSnapshot(
                id: subagentID,
                path: path,
                lifecycle: signal.lifecycle ?? .running,
                activity: signal.activity ?? .thinking,
                startedAt: signal.timestamp,
                updatedAt: signal.timestamp
            )
        let isCurrent = signal.timestamp >= subagent.updatedAt

        if subagent.path != path {
            subagent.path = path
            subagent.displayName = SubagentSnapshot.name(from: path)
        }
        if let lifecycle = signal.lifecycle, isCurrent {
            subagent.lifecycle = lifecycle
        }
        if let activity = signal.activity, isCurrent || subagent.activity == nil {
            subagent.activity = activity
        }
        if let latestStep = signal.latestStep, isCurrent || subagent.latestStep == nil {
            subagent.latestStep = latestStep
        }
        if let tokenUsage = signal.tokenUsage,
           tokenUsage.total >= (subagent.tokenUsage?.total ?? 0) {
            subagent.tokenUsage = tokenUsage
        }
        subagent.updatedAt = max(subagent.updatedAt, signal.timestamp)

        task.subagents.removeAll { $0.id == subagentID }
        task.subagents.append(subagent)
        task.subagents.sort {
            if $0.isTerminal != $1.isTerminal {
                return !$0.isTerminal
            }
            return $0.startedAt < $1.startedAt
        }
        task.updatedAt = max(task.updatedAt, signal.timestamp)
        if task.lifecycle == .running {
            task.activity = task.subagents.contains { !$0.isTerminal }
                ? .delegating
                : .thinking
        }
    }

    private mutating func applyRequestState(
        _ signal: CodexRolloutSignal,
        to task: inout TaskSnapshot
    ) {
        switch signal.requestKind {
        case .approval:
            requestsByTaskID[task.id] = PendingRequest(
                taskID: task.id,
                kind: .approval,
                summary: signal.summary
            )
            // rollout 只能观察等待状态，不能授予真实批准能力。
            task.capabilities = task.capabilities.intersection([.approve, .deny])
        case .question:
            requestsByTaskID[task.id] = PendingRequest(
                taskID: task.id,
                kind: .question,
                summary: signal.summary
            )
            task.capabilities = []
        case nil:
            if signal.lifecycle == .running || task.isTerminal {
                requestsByTaskID.removeValue(forKey: task.id)
                task.capabilities = []
            }
        }
    }

    private mutating func commitIfChanged(
        previousTasks: [TaskSnapshot],
        previousRequests: [String: PendingRequest]
    ) -> Bool {
        guard previousTasks != store.tasks || previousRequests != requestsByTaskID else {
            return false
        }
        revision &+= 1
        return true
    }

    private func unsupported(
        _ control: AuthorizedTaskControl,
        reason: String
    ) -> TaskControlReceipt {
        TaskControlReceipt(
            requestID: control.requestID,
            result: .unsupported,
            reason: reason
        )
    }

    private var latestUpdateDate: Date? {
        store.tasks.map(\.updatedAt).max()
    }

    private static func signalOrder(
        _ lhs: CodexRolloutSignal,
        _ rhs: CodexRolloutSignal
    ) -> Bool {
        if lhs.timestamp == rhs.timestamp {
            if lhs.sessionID == rhs.sessionID {
                return (lhs.subagentID ?? "") < (rhs.subagentID ?? "")
            }
            return lhs.sessionID < rhs.sessionID
        }
        return lhs.timestamp < rhs.timestamp
    }
}
