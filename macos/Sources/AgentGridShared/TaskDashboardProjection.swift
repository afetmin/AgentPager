import Foundation

/// 任务列表与“状态态”仪表盘的展示投影，规则与 Android 端 `TaskDashboardProjector` 一致。
public struct TaskDashboardProjection: Equatable, Sendable {
    public var orderedTasks: [TaskSnapshot]
    public var focusedTaskID: String?
    public var visibleTaskIDs: [String]
    public var enteringVisibleTaskIDs: Set<String>
    public var urgentTaskID: String?
    public var automaticallyExpandedTaskID: String?
    public var dashboardVisible: Bool
    public var manualDashboardOverride: Bool?
    public var nextDashboardAt: Date?
    var terminalStates: [String: Bool]

    public static let empty = TaskDashboardProjection(
        orderedTasks: [],
        focusedTaskID: nil,
        visibleTaskIDs: [],
        enteringVisibleTaskIDs: [],
        urgentTaskID: nil,
        automaticallyExpandedTaskID: nil,
        dashboardVisible: true,
        manualDashboardOverride: nil,
        nextDashboardAt: nil,
        terminalStates: [:]
    )

    public var focusedTask: TaskSnapshot? {
        orderedTasks.first { $0.id == focusedTaskID }
    }

    public var visibleTasks: [TaskSnapshot] {
        let visible = Set(visibleTaskIDs)
        return orderedTasks.filter { visible.contains($0.id) }
    }

    public func focusing(_ taskID: String) -> TaskDashboardProjection {
        guard orderedTasks.contains(where: { $0.id == taskID }) else { return self }
        var copy = self
        copy.focusedTaskID = taskID
        return copy
    }

    public func togglingDashboard() -> TaskDashboardProjection {
        var copy = self
        copy.dashboardVisible.toggle()
        copy.manualDashboardOverride = copy.dashboardVisible
        return copy
    }
}

public enum TaskDashboardProjector {
    public static let idleDelay: TimeInterval = 90
    public static let visibleTaskLimit = 5

    public static func project(
        snapshot: StateSnapshotPayload,
        previous: TaskDashboardProjection?,
        now: Date
    ) -> TaskDashboardProjection {
        project(
            tasks: snapshot.tasks,
            preferredFocusedTaskID: snapshot.focusedTaskID,
            previous: previous,
            now: now
        )
    }

    public static func project(
        tasks: [TaskSnapshot],
        preferredFocusedTaskID: String?,
        previous: TaskDashboardProjection?,
        now: Date,
        idleDelay: TimeInterval = idleDelay,
        visibleLimit: Int = visibleTaskLimit
    ) -> TaskDashboardProjection {
        precondition(idleDelay >= 0, "任务结束等待时间不能为负数")
        precondition(visibleLimit > 0, "可见任务数量必须大于零")

        let ordered = normalize(tasks).sorted(by: precedes)
        let visibleIDs = ordered.prefix(visibleLimit).map(\.id)
        let entering: Set<String>
        if let previousVisible = previous?.visibleTaskIDs, !previousVisible.isEmpty {
            entering = Set(visibleIDs.filter { !previousVisible.contains($0) })
        } else {
            entering = []
        }
        let terminalStates = Dictionary(uniqueKeysWithValues: ordered.map { ($0.id, $0.isTerminal) })
        let hasNewTask = previous.map { previous in
            ordered.contains { task in
                guard let wasTerminal = previous.terminalStates[task.id] else { return true }
                return wasTerminal && !task.isTerminal
            }
        } ?? false
        let manualOverride = hasNewTask ? nil : previous?.manualDashboardOverride
        let nextAt = nextDashboardAt(tasks: ordered, now: now, idleDelay: idleDelay)
        let automaticVisible = nextAt == nil && !ordered.contains { !$0.isTerminal }
        let focusedID = preferredFocusedTaskID.flatMap { id in ordered.contains { $0.id == id } ? id : nil }
            ?? previous?.focusedTaskID.flatMap { id in ordered.contains { $0.id == id } ? id : nil }
            ?? ordered.max(by: focusIsLower)?.id
        let urgentID = ordered.first {
            $0.lifecycle == .waitingApproval || $0.lifecycle == .waitingAnswer
        }?.id
        let expandedID = urgentID ?? ordered.first { task in
            task.subagents.contains { !$0.isTerminal }
        }?.id

        return TaskDashboardProjection(
            orderedTasks: ordered,
            focusedTaskID: focusedID,
            visibleTaskIDs: Array(visibleIDs),
            enteringVisibleTaskIDs: entering,
            urgentTaskID: urgentID,
            automaticallyExpandedTaskID: expandedID,
            dashboardVisible: manualOverride ?? automaticVisible,
            manualDashboardOverride: manualOverride,
            nextDashboardAt: nextAt,
            terminalStates: terminalStates
        )
    }

    /// 重复 ID 保留更新时间较新的；更新时间相同保留最后出现的。
    private static func normalize(_ tasks: [TaskSnapshot]) -> [TaskSnapshot] {
        var best: [String: (index: Int, task: TaskSnapshot)] = [:]
        for (index, task) in tasks.enumerated() {
            if let current = best[task.id], current.task.updatedAt > task.updatedAt {
                continue
            }
            best[task.id] = (index, task)
        }
        return best.values.sorted { $0.index < $1.index }.map(\.task)
    }

    private static func nextDashboardAt(
        tasks: [TaskSnapshot],
        now: Date,
        idleDelay: TimeInterval
    ) -> Date? {
        guard !tasks.contains(where: { !$0.isTerminal }) else { return nil }
        guard let lastFinished = tasks.map({ $0.completedAt ?? $0.updatedAt }).max() else {
            return nil
        }
        let transition = lastFinished.addingTimeInterval(idleDelay)
        return transition > now ? transition : nil
    }

    private static func precedes(_ lhs: TaskSnapshot, _ rhs: TaskSnapshot) -> Bool {
        if lhs.sortGroup != rhs.sortGroup { return lhs.sortGroup > rhs.sortGroup }
        if lhs.listPriority != rhs.listPriority { return lhs.listPriority > rhs.listPriority }
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        return lhs.id < rhs.id
    }

    /// 自动焦点：注意力优先级最高，其次更新更晚，再次 ID 更小。
    private static func focusIsLower(_ lhs: TaskSnapshot, _ rhs: TaskSnapshot) -> Bool {
        if lhs.effectivePriority != rhs.effectivePriority {
            return lhs.effectivePriority < rhs.effectivePriority
        }
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt < rhs.updatedAt }
        return lhs.id > rhs.id
    }
}

private extension TaskSnapshot {
    var listPriority: Int {
        switch lifecycle {
        // 已读状态只控制提醒，不应让展开操作改变 Task 位置。
        case .succeeded: isPinned ? 1 : 0
        default: effectivePriority
        }
    }

    var sortGroup: Int {
        switch lifecycle {
        // 等待回答与等待批准一样需要人工介入，不能沉到运行中任务下面被挤出可见范围。
        case .waitingApproval, .waitingAnswer: 3
        case .running: 2
        case .succeeded: 0
        default: 1
        }
    }
}

extension TaskSnapshot {
    /// 终态消息缺 `completedAt` 时回退到 `updatedAt`。
    public func elapsed(at now: Date) -> TimeInterval {
        let end = isTerminal ? (completedAt ?? updatedAt) : now
        return max(0, end.timeIntervalSince(startedAt))
    }
}
