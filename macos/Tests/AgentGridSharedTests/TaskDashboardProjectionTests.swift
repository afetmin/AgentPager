import Foundation
import Testing
@testable import AgentGridShared

private let now = Date(timeIntervalSince1970: 1_000)

private func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

private func task(
    _ id: String,
    _ lifecycle: AgentLifecycle,
    _ updatedAt: TimeInterval,
    completedAt: TimeInterval? = nil,
    isUnread: Bool = false,
    title: String? = nil
) -> TaskSnapshot {
    TaskSnapshot(
        id: id,
        source: .codexCLI,
        projectName: id,
        title: title ?? id,
        lifecycle: lifecycle,
        startedAt: at(0),
        updatedAt: at(updatedAt),
        completedAt: completedAt.map(at),
        isUnread: isUnread
    )
}

private func project(
    _ tasks: [TaskSnapshot],
    previous: TaskDashboardProjection? = nil,
    at date: Date = now
) -> TaskDashboardProjection {
    TaskDashboardProjector.project(
        tasks: tasks,
        preferredFocusedTaskID: nil,
        previous: previous,
        now: date
    )
}

@Test("排序分组稳定且已读变化不移动完成任务")
func orderingIsStableAcrossReadChanges() {
    let approval = task("approval", .waitingApproval, 10)
    let running = task("running", .running, 30)
    let starting = task("starting", .starting, 40)
    var succeededB = task("b", .succeeded, 20, isUnread: true)
    let succeededA = task("a", .succeeded, 20)

    let before = project([succeededB, starting, succeededA, running, approval]).orderedTasks.map(\.id)
    succeededB.isUnread = false
    let after = project([succeededB, starting, succeededA, running, approval]).orderedTasks.map(\.id)

    #expect(before == ["approval", "running", "starting", "a", "b"])
    #expect(after == before)
}

@Test("等待回答与等待批准同组置顶不会被运行中任务挤出")
func waitingTasksAreNeverPushedOut() {
    let running = (1...6).map { task("run\($0)", .running, 100 + TimeInterval($0)) }
    let answer = task("answer", .waitingAnswer, 1)
    let approval = task("approval", .waitingApproval, 2)

    let projection = project(running + [answer, approval])

    #expect(projection.orderedTasks.prefix(2).map(\.id) == ["approval", "answer"])
    #expect(projection.visibleTaskIDs.contains("answer"))
    #expect(projection.urgentTaskID == "approval")
}

@Test("重复 ID 保留更新时间较新且同时间保留最后一个")
func duplicateIDsKeepNewestThenLast() {
    let old = task("same", .running, 10)
    let newer = task("same", .running, 20)
    var last = newer
    last.title = "最后一个"

    let projection = project([old, newer, last])

    #expect(projection.orderedTasks.count == 1)
    #expect(projection.orderedTasks.first?.title == "最后一个")
}

@Test("列表换位不算进入而列表外任务进入前五会标记")
func enteringTasksAreMarkedOnlyWhenNewlyVisible() {
    let original = (1...6).map { task("task-\($0)", .running, TimeInterval(100 - $0)) }
    let first = project(original)
    let reordered = project(
        original.map { $0.id == "task-2" ? task("task-2", .running, 200) : $0 },
        previous: first
    )
    let entered = project(
        original.map { $0.id == "task-6" ? task("task-6", .running, 300) : $0 },
        previous: first
    )

    #expect(reordered.enteringVisibleTaskIDs.isEmpty)
    #expect(entered.enteringVisibleTaskIDs == ["task-6"])
}

@Test("远端焦点优先否则保留用户焦点再回退自动焦点")
func focusPrecedence() {
    let running = task("running", .running, 30)
    let approval = task("approval", .waitingApproval, 10)
    let automatic = project([running, approval])
    let userFocused = automatic.focusing("running")

    let retained = TaskDashboardProjector.project(
        snapshot: StateSnapshotPayload(tasks: [running, approval], usage: nil, focusedTaskID: nil),
        previous: userFocused,
        now: now
    )
    let remote = TaskDashboardProjector.project(
        snapshot: StateSnapshotPayload(tasks: [running, approval], usage: nil, focusedTaskID: "approval"),
        previous: userFocused,
        now: now
    )

    #expect(automatic.focusedTaskID == "approval")
    #expect(retained.focusedTaskID == "running")
    #expect(remote.focusedTaskID == "approval")
}

@Test("审批任务优先自动展开否则展开活跃 Subagent")
func automaticExpansion() {
    var delegated = task("delegated", .running, 30)
    delegated.subagents = [SubagentSnapshot(
        id: "subagent",
        path: "/root/subagent",
        displayName: "子代理",
        lifecycle: .running,
        startedAt: at(1),
        updatedAt: at(2)
    )]
    let approval = task("approval", .waitingApproval, 10)

    let delegatedOnly = project([delegated])
    let urgent = project([delegated, approval])

    #expect(delegatedOnly.automaticallyExpandedTaskID == "delegated")
    #expect(delegatedOnly.urgentTaskID == nil)
    #expect(urgent.automaticallyExpandedTaskID == "approval")
    #expect(urgent.urgentTaskID == "approval")
}

@Test("空列表立即显示 Dashboard，活跃任务始终显示任务态")
func dashboardVisibility() {
    #expect(project([]).dashboardVisible)
    #expect(!project([task("running", .running, 1_000)]).dashboardVisible)
}

@Test("全部终态只返回一次九十秒绝对切换时间")
func idleSwitchTime() {
    let completedAt: TimeInterval = 970
    let completed = task("done", .succeeded, completedAt, completedAt: completedAt)

    let waiting = project([completed])
    let expired = project([completed], previous: waiting, at: at(1_060))

    #expect(!waiting.dashboardVisible)
    #expect(waiting.nextDashboardAt == at(1_060))
    #expect(expired.dashboardVisible)
    #expect(expired.nextDashboardAt == nil)
}

@Test("手动覆盖会保留直到新增任务或终态任务复活")
func manualOverrideLifetime() {
    let running = task("existing", .running, 10)
    let hidden = project([running]).togglingDashboard()
    let ordinaryUpdate = project([task("existing", .running, 20)], previous: hidden)
    let newTask = project(
        [task("existing", .running, 30), task("new", .starting, 40)],
        previous: ordinaryUpdate
    )
    let completed = project([task("existing", .succeeded, 50, completedAt: 50)]).togglingDashboard()
    let restarted = project([task("existing", .starting, 60)], previous: completed)

    #expect(ordinaryUpdate.manualDashboardOverride == true)
    #expect(newTask.manualDashboardOverride == nil)
    #expect(!newTask.dashboardVisible)
    #expect(restarted.manualDashboardOverride == nil)
    #expect(!restarted.dashboardVisible)
}

@Test("终态缺完成时间时使用更新时间，时钟倒退仍确定")
func terminalWithoutCompletionTime() {
    let completed = task("done", .interrupted, 1_010)

    let projection = project([completed])

    #expect(projection.nextDashboardAt == at(1_100))
    #expect(!projection.dashboardVisible)
}

@Test("任务耗时：运行中随时间增长，终态固定在完成时间")
func elapsedTime() {
    let running = task("r", .running, 100)
    let done = task("d", .succeeded, 100, completedAt: 160)
    let noCompletion = task("n", .interrupted, 140)

    #expect(running.elapsed(at: at(500)) == 500)
    #expect(done.elapsed(at: at(9_999)) == 160)
    #expect(noCompletion.elapsed(at: at(9_999)) == 140)
}
