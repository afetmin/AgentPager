import AgentGridShared
import SwiftUI

struct TaskListView: View {
    let model: AppModel
    let compact: Bool
    @State private var expandedTaskID: String?

    private struct AutoExpansion: Equatable {
        var taskID: String?
        var lifecycle: AgentLifecycle?
        var subagents: [String]
    }

    private var autoExpansion: AutoExpansion {
        let task = model.projection.orderedTasks.first { $0.id == model.projection.automaticallyExpandedTaskID }
        return AutoExpansion(
            taskID: task?.id,
            lifecycle: task?.lifecycle,
            subagents: task?.subagents.map { "\($0.id):\($0.lifecycle.rawValue)" } ?? []
        )
    }

    var body: some View {
        let projection = model.projection
        let tasks = projection.visibleTasks
        ScrollView {
            LazyVStack(spacing: 0) {
                if tasks.isEmpty {
                    Text("暂无任务")
                        .font(.pixel(12))
                        .foregroundStyle(PixelTheme.dimmed)
                        .padding(.top, 48)
                }
                ForEach(Array(tasks.enumerated()), id: \.element.id) { index, task in
                    TaskRowView(
                        task: task,
                        pending: model.state.snapshot.pendingRequests.first { $0.taskID == task.id },
                        expanded: expandedTaskID == task.id,
                        dimmed: projection.urgentTaskID != nil && projection.urgentTaskID != task.id,
                        compact: compact,
                        showDivider: index < tasks.count - 1,
                        onTap: {
                            withAnimation(.easeOut(duration: 0.26)) {
                                expandedTaskID = expandedTaskID == task.id ? nil : task.id
                            }
                            model.select(task)
                        },
                        onControl: { action, value in model.send(action, taskID: task.id, value: value) }
                    )
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .opacity
                    ))
                }
            }
            .padding(.horizontal, compact ? 12 : 20)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
            .animation(.spring(response: 0.38, dampingFraction: 1), value: tasks.map(\.id))
        }
        .scrollIndicators(.hidden)
        .onAppear { expandAutomatically() }
        .onChange(of: autoExpansion) { expandAutomatically() }
    }

    private func expandAutomatically() {
        guard let id = autoExpansion.taskID else { return }
        withAnimation(.easeOut(duration: 0.26)) { expandedTaskID = id }
    }
}

private struct TaskRowView: View {
    let task: TaskSnapshot
    let pending: PendingRequest?
    let expanded: Bool
    let dimmed: Bool
    let compact: Bool
    let showDivider: Bool
    let onTap: () -> Void
    let onControl: (ControlAction, String?) -> Void

    private var coreSize: CGFloat { compact ? 56 : 70 }
    private var statusColor: Color { PixelTheme.color(lifecycle: task.lifecycle, activity: task.activity) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TaskPixelCore(task: task)
                    .frame(width: coreSize, height: coreSize)
                    .accessibilityLabel("任务状态 \(TaskPresentation.statusText(task))")

                VStack(alignment: .leading, spacing: 3) {
                    Text(task.title)
                        .font(.pixel(15, weight: .bold))
                        .foregroundStyle(PixelTheme.text)
                        .lineLimit(1)
                    if TaskPresentation.shouldShowTokenSummary(task) {
                        Text("TOKEN  \(TaskPresentation.tokenDetailsText(task))")
                            .font(.pixel(11))
                            .foregroundStyle(PixelTheme.cyan)
                            .lineLimit(1)
                    } else {
                        Text(task.userPrompt.map { "你：\($0)" } ?? "你：—")
                            .font(.pixel(12))
                            .foregroundStyle(PixelTheme.muted)
                            .lineLimit(1)
                        CommandTicker(text: task.latestStep ?? TaskPresentation.statusText(task), color: statusColor)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                TaskMeta(task: task, compact: compact, statusColor: statusColor)
            }
            .frame(minHeight: 78)
            .opacity(dimmed ? 0.34 : 1)
            .animation(.easeOut(duration: 0.18), value: dimmed)

            if expanded {
                TaskDetails(task: task, pending: pending, onControl: onControl)
                    .padding(.leading, coreSize + 8)
                    .padding(.trailing, 6)
                    .padding(.bottom, 10)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if showDivider {
                Rectangle()
                    .fill(PixelTheme.divider.opacity(0.85))
                    .frame(height: 1)
                    .padding(.leading, coreSize + 8)
            }
        }
        .padding(.horizontal, 4)
        .background(expanded ? PixelTheme.surface : .clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .accessibilityElement(children: .contain)
    }
}

/// 像素核心：只在生命周期或活动变化时重新计时，普通内容更新不会重放动画。
private struct TaskPixelCore: View {
    let task: TaskSnapshot
    @State private var changedAt: Date

    init(task: TaskSnapshot) {
        self.task = task
        _changedAt = State(initialValue: task.updatedAt)
    }

    private struct Key: Equatable {
        var lifecycle: AgentLifecycle
        var activity: AgentActivity?
    }

    var body: some View {
        PixelCoreView(
            lifecycle: task.lifecycle,
            activity: task.activity,
            changedAt: changedAt,
            compact: false
        )
        .onChange(of: Key(lifecycle: task.lifecycle, activity: task.activity)) {
            changedAt = .now
        }
    }
}

private struct CommandTicker: View {
    let text: String
    let color: Color

    var body: some View {
        ZStack(alignment: .leading) {
            Text(text)
                .font(.pixel(12))
                .foregroundStyle(color)
                .lineLimit(1)
                .id(text)
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal: .move(edge: .top).combined(with: .opacity)
                ))
        }
        .frame(maxWidth: .infinity, minHeight: 18, alignment: .leading)
        .clipped()
        .animation(.easeOut(duration: 0.22), value: text)
    }
}

private struct TaskMeta: View {
    let task: TaskSnapshot
    let compact: Bool
    let statusColor: Color

    var body: some View {
        VStack(alignment: .trailing, spacing: 7) {
            HStack(spacing: 6) {
                MetaTag(text: TaskPresentation.agentBadge(task), color: PixelTheme.agentBadgeColor(task))
                if !compact {
                    MetaTag(text: TaskPresentation.agentOrigin(task), color: PixelTheme.muted)
                }
            }
            HStack(spacing: 10) {
                if !compact {
                    Text(TaskPresentation.tokensText(task.tokenUsage?.total))
                        .font(.pixel(11))
                        .foregroundStyle(PixelTheme.muted)
                }
                if task.isTerminal {
                    Text(TaskPresentation.elapsedText(task.elapsed(at: .now)))
                        .font(.pixel(11))
                        .foregroundStyle(PixelTheme.muted)
                } else {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(TaskPresentation.elapsedText(task.elapsed(at: context.date)))
                            .font(.pixel(11))
                            .foregroundStyle(PixelTheme.muted)
                    }
                }
                Rectangle().fill(statusColor).frame(width: 7, height: 7)
            }
        }
    }
}

private struct MetaTag: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.pixel(11))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(PixelTheme.raised)
    }
}

private struct TaskDetails: View {
    let task: TaskSnapshot
    let pending: PendingRequest?
    let onControl: (ControlAction, String?) -> Void
    @State private var answer = ""
    @State private var confirmingInterrupt = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !task.subagents.isEmpty {
                SubagentPanel(agentName: TaskPresentation.agentBadge(task), subagents: task.subagents)
            }
            if task.tokenUsage != nil {
                DetailLine(label: "TOKEN", value: TaskPresentation.tokenDetailsText(task), color: PixelTheme.cyan)
            }
            if let pending {
                if let summary = pending.summary {
                    DetailLine(
                        label: pending.kind == .approval ? "APPROVAL" : "QUESTION",
                        value: summary,
                        color: pending.kind == .approval ? PixelTheme.amber : PixelTheme.yellow
                    )
                }
                if pending.kind == .approval, task.capabilities.contains(.approve) {
                    HStack(spacing: 8) {
                        PixelButton(title: "允许", color: PixelTheme.green) { onControl(.approve, nil) }
                        if task.capabilities.contains(.deny) {
                            PixelButton(title: "拒绝", color: PixelTheme.red) { onControl(.deny, nil) }
                        }
                    }
                } else if pending.kind == .question, task.capabilities.contains(.answer) {
                    questionControls(pending)
                }
            }
            if showsInterrupt || task.capabilities.contains(.retry) {
                HStack(spacing: 8) {
                    if showsInterrupt {
                        PixelButton(title: "中断", color: PixelTheme.orange) { confirmingInterrupt = true }
                    }
                    if task.capabilities.contains(.retry) {
                        PixelButton(title: "重试", color: PixelTheme.blue) { onControl(.retry, nil) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .confirmationDialog("中断这个任务？", isPresented: $confirmingInterrupt, titleVisibility: .visible) {
            Button("中断", role: .destructive) { onControl(.interrupt, nil) }
        }
    }

    private var showsInterrupt: Bool {
        task.capabilities.contains(.interrupt) && !task.isTerminal
    }

    @ViewBuilder
    private func questionControls(_ pending: PendingRequest) -> some View {
        ForEach(pending.options, id: \.self) { option in
            PixelButton(title: option, color: PixelTheme.yellow) { onControl(.answer, option) }
        }
        TextField("输入回答", text: $answer, axis: .vertical)
            .font(.pixel(12))
            .lineLimit(1...3)
            .textFieldStyle(.plain)
            .foregroundStyle(PixelTheme.text)
            .padding(10)
            .background(PixelTheme.raised)
            .overlay(Rectangle().stroke(PixelTheme.divider, lineWidth: 1))
        PixelButton(title: "发送回答", color: PixelTheme.yellow) {
            let text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            onControl(.answer, text)
            answer = ""
        }
    }
}

private struct DetailLine: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.pixel(10, weight: .bold))
                .foregroundStyle(color)
            Text(value)
                .font(.pixel(12))
                .foregroundStyle(PixelTheme.text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct SubagentPanel: View {
    let agentName: String
    let subagents: [SubagentSnapshot]

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("\(agentName.uppercased()) (\(subagents.count))")
                .font(.pixel(11, weight: .bold))
                .foregroundStyle(PixelTheme.muted)
            ForEach(subagents) { subagent in
                SubagentRow(subagent: subagent)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PixelTheme.raised)
    }
}

private struct SubagentRow: View {
    let subagent: SubagentSnapshot

    var body: some View {
        let color = PixelTheme.color(lifecycle: subagent.lifecycle, activity: subagent.activity)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Rectangle().fill(color).frame(width: 6, height: 6)
                Text(subagent.displayName)
                    .font(.pixel(12, weight: .bold))
                    .foregroundStyle(PixelTheme.text)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let total = subagent.tokenUsage?.total, total > 0 {
                    Text(TaskPresentation.tokensText(total))
                        .font(.pixel(10))
                        .foregroundStyle(PixelTheme.muted)
                }
                TimelineView(.periodic(from: .now, by: subagent.isTerminal ? 3_600 : 1)) { context in
                    Text("\(TaskPresentation.lifecycleText(subagent.lifecycle)) · \(TaskPresentation.elapsedText(subagent.elapsed(at: context.date)))")
                        .font(.pixel(10))
                        .foregroundStyle(color)
                        .lineLimit(1)
                }
            }
            if let step = subagent.latestStep {
                Text(step)
                    .font(.pixel(11))
                    .foregroundStyle(PixelTheme.muted)
                    .lineLimit(1)
                    .padding(.leading, 14)
            }
        }
    }
}
