import AgentGridShared
import SwiftUI

/// M2 的最小状态页：展示连接、任务、待处理请求，并验证签名控制。完整仪表盘在 M3 实现。
struct StatusView: View {
    let model: AppModel
    @State private var confirmingUnpair = false

    private var state: PhoneSessionState { model.state }
    private var pending: [PendingRequest] { state.snapshot.pendingRequests }

    var body: some View {
        List {
            Section("连接") {
                LabeledContent("状态", value: linkText)
                if let pairing = state.pairing {
                    LabeledContent("Mac", value: "\(pairing.host):\(pairing.port)")
                }
                if let problem = state.problem {
                    Label(AppModel.message(for: problem), systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }

            if let error = model.controlError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
            }
            if let last = state.controls.last {
                Section("最近一次操作") {
                    Text(deliveryText(last.delivery))
                }
            }

            Section("任务") {
                if state.snapshot.tasks.isEmpty {
                    Text("暂无任务").foregroundStyle(.secondary)
                }
                ForEach(state.snapshot.tasks) { task in
                    TaskRow(
                        task: task,
                        request: pending.first { $0.taskID == task.id },
                        send: { action, value in model.send(action, to: task, value: value) }
                    )
                }
            }

            Section {
                Button("解除配对", role: .destructive) { confirmingUnpair = true }
            }
        }
        .navigationTitle("AgentPager")
        .confirmationDialog("解除配对后需要重新扫码才能连接。", isPresented: $confirmingUnpair, titleVisibility: .visible) {
            Button("解除配对", role: .destructive) { model.unpair() }
        }
    }

    private var linkText: String {
        switch state.link {
        case .connected: "已连接"
        case .connecting: "连接中…"
        case .disconnected: "已断开"
        }
    }

    private func deliveryText(_ delivery: ControlDelivery) -> String {
        switch delivery {
        case .pending: "等待 Mac 确认…"
        case let .acknowledged(result, reason):
            switch result {
            case .accepted: "Mac 已执行"
            case .rejected: "Mac 拒绝：\(reason ?? "未说明原因")"
            case .stale: "请求已过期"
            case .unsupported: "该操作不受支持"
            }
        case .timedOut: "Mac 没有回应"
        case .sendFailed: "发送失败"
        }
    }
}

private struct TaskRow: View {
    let task: TaskSnapshot
    let request: PendingRequest?
    let send: (ControlAction, String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(task.projectName).font(.headline)
                Spacer()
                Text(task.lifecycle.label).font(.caption).foregroundStyle(.secondary)
            }
            if task.title != task.projectName {
                Text(task.title).font(.subheadline)
            }
            if let step = task.latestStep {
                Text(step).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
            }
            if let summary = request?.summary {
                Text(summary).font(.footnote).padding(.vertical, 2)
            }
            controls
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var controls: some View {
        HStack {
            if task.capabilities.contains(.approve) {
                Button("批准") { send(.approve, nil) }.buttonStyle(.borderedProminent)
            }
            if task.capabilities.contains(.deny) {
                Button("拒绝") { send(.deny, nil) }.buttonStyle(.bordered)
            }
            if task.capabilities.contains(.interrupt) {
                Button("中断", role: .destructive) { send(.interrupt, nil) }.buttonStyle(.bordered)
            }
            if task.capabilities.contains(.retry) {
                Button("重试") { send(.retry, nil) }.buttonStyle(.bordered)
            }
        }
        if task.capabilities.contains(.answer), let options = request?.options, !options.isEmpty {
            ForEach(options, id: \.self) { option in
                Button(option) { send(.answer, option) }.buttonStyle(.bordered)
            }
        }
    }
}

extension AgentLifecycle {
    var label: String {
        switch self {
        case .offline: "离线"
        case .idle: "空闲"
        case .starting: "启动中"
        case .running: "运行中"
        case .waitingApproval: "等待批准"
        case .waitingAnswer: "等待回答"
        case .succeeded: "已完成"
        case .interrupted: "已中断"
        }
    }
}
