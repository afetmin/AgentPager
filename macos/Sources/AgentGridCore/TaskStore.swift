import Foundation

public struct TaskStore: Sendable {
    public private(set) var tasks: [TaskSnapshot]
    public var retention: TimeInterval
    public var syntheticRetention: TimeInterval
    public var capacity: Int

    public init(
        tasks: [TaskSnapshot] = [],
        retention: TimeInterval = 60 * 60,
        syntheticRetention: TimeInterval = 60,
        capacity: Int = 20
    ) {
        self.tasks = tasks
        self.retention = retention
        self.syntheticRetention = syntheticRetention
        self.capacity = capacity
    }

    public mutating func upsert(_ task: TaskSnapshot) {
        if let index = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[index] = task
        } else {
            tasks.append(task)
        }
        purge(now: task.updatedAt)
    }

    public mutating func remove(id: String) {
        tasks.removeAll { $0.id == id }
    }

    @discardableResult
    public mutating func applyTitles(_ titlesByTaskID: [String: String]) -> Bool {
        var changed = false
        for index in tasks.indices {
            guard let codexTitle = titlesByTaskID[tasks[index].id] else {
                continue
            }
            let title = Self.displayTitle(
                projectName: tasks[index].projectName,
                codexTitle: codexTitle
            )
            guard tasks[index].title != title else {
                continue
            }
            tasks[index].title = title
            changed = true
        }
        return changed
    }

    static func displayTitle(
        projectName: String,
        codexTitle: String
    ) -> String {
        let prefix = "\(projectName) · "
        guard codexTitle != projectName,
              !codexTitle.hasPrefix(prefix) else {
            return codexTitle
        }
        return "\(prefix)\(codexTitle)"
    }

    public mutating func purge(now: Date = .now) {
        tasks.removeAll { task in
            // 测试与状态模拟任务没有真实 Codex 会话，短暂展示后必须主动收敛。
            if task.id.hasPrefix("agentgrid-"),
               now.timeIntervalSince(task.updatedAt) >= syntheticRetention {
                return true
            }
            // SessionEnd/启动超时会进入 offline；它不是可恢复的活跃任务，
            // 也没有 completedAt，必须使用最后活动时间收敛，否则会永久留在列表。
            if task.lifecycle == .offline,
               now.timeIntervalSince(task.updatedAt) > retention {
                return true
            }
            guard task.isTerminal, let completedAt = task.completedAt else {
                return false
            }
            return now.timeIntervalSince(completedAt) > retention
        }

        guard tasks.count > capacity else {
            return
        }

        let removable = tasks
            .filter(\.isTerminal)
            .sorted { $0.updatedAt < $1.updatedAt }
            .map(\.id)

        for id in removable where tasks.count > capacity {
            tasks.removeAll { $0.id == id }
        }
    }

    @discardableResult
    public mutating func interruptOrphanedCodexTasks(
        existingSessionIDs: Set<String>,
        liveSessionIDs: Set<String>? = nil,
        now: Date = .now,
        gracePeriod: TimeInterval = 10 * 60
    ) -> Bool {
        var changed = false
        for index in tasks.indices {
            let task = tasks[index]
            guard task.source == .codexDesktop || task.source == .codexCLI,
                  task.lifecycle == .starting || task.lifecycle == .running,
                  now.timeIntervalSince(task.updatedAt) >= gracePeriod else {
                continue
            }
            let missingRollout = !existingSessionIDs.contains(task.id)
            let stoppedWriter = liveSessionIDs.map { !$0.contains(task.id) } ?? false
            guard missingRollout || stoppedWriter else {
                continue
            }

            // 保留最后一次真实活动时间，让已有终态保留策略决定是否立即移除。
            tasks[index].lifecycle = .interrupted
            tasks[index].activity = nil
            tasks[index].completedAt = task.updatedAt
            tasks[index].isUnread = true
            tasks[index].capabilities = []
            changed = true
        }
        return changed
    }

    /// 用 Claude 会话文件纠正丢失/乱序 Hook 导致的僵尸状态。
    @discardableResult
    public mutating func reconcileClaudeTasks(
        evidenceBySessionID: [String: ClaudeTranscriptEvidence],
        now: Date = .now,
        startingGracePeriod: TimeInterval = 2 * 60,
        inactivityGracePeriod: TimeInterval = 10 * 60
    ) -> Bool {
        var changed = false
        for index in tasks.indices {
            let task = tasks[index]
            guard task.source == .claudeCode,
                  task.lifecycle == .starting || task.lifecycle == .running else {
                continue
            }
            let evidence = evidenceBySessionID[task.id]

            // Transcript 的 stop_hook_summary 是 Claude Desktop/Code 已结束本轮
            // 的持久证据，即使随后有迟到 Hook 刷新了 task.updatedAt 也应收敛。
            if let completedAt = evidence?.completedAt,
               completedAt >= task.startedAt {
                tasks[index].lifecycle = .succeeded
                tasks[index].activity = nil
                tasks[index].completedAt = completedAt
                tasks[index].isUnread = true
                tasks[index].capabilities = []
                changed = true
                continue
            }

            // UserPromptSubmit Hook 偶尔会被 Desktop 的预热路径漏掉；会话文件
            // 中出现了尚未 Stop 的用户轮次时，直接从 STARTING 纠正为 RUNNING。
            if task.lifecycle == .starting, evidence?.hasOpenTurn == true,
               (evidence?.lastActivityAt ?? .distantPast) >= task.startedAt {
                tasks[index].lifecycle = .running
                tasks[index].activity = .thinking
                tasks[index].updatedAt = max(
                    task.updatedAt,
                    evidence?.lastActivityAt ?? task.updatedAt
                )
                tasks[index].completedAt = nil
                tasks[index].capabilities = []
                changed = true
                continue
            }

            if task.lifecycle == .starting,
               now.timeIntervalSince(task.updatedAt) >= startingGracePeriod {
                tasks[index].lifecycle = .offline
                tasks[index].activity = nil
                tasks[index].capabilities = []
                changed = true
                continue
            }

            let lastEvidenceAt = evidence?.lastActivityAt ?? evidence?.modificationDate
            let lastKnownActivity = max(task.updatedAt, lastEvidenceAt ?? task.updatedAt)
            if task.lifecycle == .running,
               evidence == nil,
               now.timeIntervalSince(lastKnownActivity) >= inactivityGracePeriod {
                // Silence alone is not proof that an existing Claude turn
                // stopped: Bash tools and model calls can run for a long time.
                tasks[index].lifecycle = .interrupted
                tasks[index].activity = nil
                tasks[index].completedAt = lastKnownActivity
                tasks[index].isUnread = true
                tasks[index].capabilities = []
                changed = true
            }
        }
        return changed
    }

    @discardableResult
    public mutating func purgeTerminalSubagents(
        now: Date = .now,
        retention: TimeInterval = 4
    ) -> Bool {
        var changed = false
        for index in tasks.indices {
            let previousCount = tasks[index].subagents.count
            tasks[index].subagents.removeAll { subagent in
                subagent.isTerminal &&
                    now.timeIntervalSince(subagent.updatedAt) >= retention
            }
            changed = changed || tasks[index].subagents.count != previousCount
        }
        return changed
    }

    public func focusedTask() -> TaskSnapshot? {
        tasks.max { lhs, rhs in
            if lhs.effectivePriority == rhs.effectivePriority {
                return lhs.updatedAt < rhs.updatedAt
            }
            return lhs.effectivePriority < rhs.effectivePriority
        }
    }
}
