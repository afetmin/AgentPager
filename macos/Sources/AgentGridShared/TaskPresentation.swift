import Foundation

/// 任务行的文案与格式化，与 Android 端 `TaskRowSummary` / `AgentGridScreen` 的辅助函数一致。
public enum TaskPresentation {
    public static func shouldShowTokenSummary(_ task: TaskSnapshot) -> Bool {
        task.lifecycle == .succeeded
    }

    public static func statusText(_ task: TaskSnapshot) -> String {
        task.lifecycle == .running ? activityText(task.activity) : lifecycleText(task.lifecycle)
    }

    public static func lifecycleText(_ lifecycle: AgentLifecycle) -> String {
        switch lifecycle {
        case .offline: "离线"
        case .idle: "空闲"
        case .starting: "正在启动"
        case .running: "正在运行"
        case .waitingApproval: "等待批准"
        case .waitingAnswer: "等待回答"
        case .succeeded: "任务完成"
        case .interrupted: "已中断"
        }
    }

    public static func activityText(_ activity: AgentActivity?) -> String {
        switch activity {
        case .thinking: "正在思考"
        case .reading: "正在读取"
        case .searching: "正在搜索"
        case .editing: "正在编辑"
        case .executing: "正在执行"
        case .testing: "正在测试"
        case .browsing: "正在浏览"
        case .delegating: "正在协作"
        case nil: "正在运行"
        }
    }

    /// 兼容 Claude Code 协议的其他客户端（ZCode、WorkBuddy 等）优先显示自己的名字。
    public static func agentBadge(_ task: TaskSnapshot) -> String {
        if let name = task.agentName, !name.trimmingCharacters(in: .whitespaces).isEmpty {
            return name
        }
        switch task.source {
        case .codexDesktop, .codexCLI: return "Codex"
        case .claudeCode: return "Claude"
        }
    }

    public static func agentOrigin(_ task: TaskSnapshot) -> String {
        if let name = task.agentName, !name.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Hook"
        }
        switch task.source {
        case .codexDesktop: return "ChatGPT.app"
        case .codexCLI: return "Terminal"
        case .claudeCode: return "Claude Code"
        }
    }

    public static func elapsedText(_ interval: TimeInterval) -> String {
        let total = Int(max(0, interval))
        let hours = total / 3_600
        let minutes = total % 3_600 / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%02d:%02d", minutes, seconds)
    }

    public static func tokensText(_ value: Int?) -> String {
        guard let value else { return "— tok" }
        if value >= 1_000_000 { return String(format: "%.1fm tok", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fk tok", Double(value) / 1_000) }
        return "\(value) tok"
    }

    public static func tokenDetailsText(_ task: TaskSnapshot) -> String {
        guard let usage = task.tokenUsage else { return "—" }
        return "IN \(tokensText(usage.input)) · CACHE \(tokensText(usage.cachedInput)) · "
            + "OUT \(tokensText(usage.output)) · TOTAL \(tokensText(usage.total))"
    }
}
