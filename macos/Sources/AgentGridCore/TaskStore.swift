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

    private static func displayTitle(
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
        now: Date = .now,
        gracePeriod: TimeInterval = 10 * 60
    ) -> Bool {
        var changed = false
        for index in tasks.indices {
            let task = tasks[index]
            guard task.source == .codexDesktop || task.source == .codexCLI,
                  task.lifecycle == .starting || task.lifecycle == .running,
                  now.timeIntervalSince(task.updatedAt) >= gracePeriod,
                  !existingSessionIDs.contains(task.id) else {
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
