import Foundation

public enum AgentSource: String, Codable, Sendable {
    case codexDesktop
    case codexCLI
    case claudeCode
}

public enum AgentLifecycle: String, Codable, CaseIterable, Sendable {
    case offline
    case idle
    case starting
    case running
    case waitingApproval
    case waitingAnswer
    case succeeded
    case interrupted

    public var attentionPriority: Int {
        switch self {
        case .waitingApproval: 600
        case .waitingAnswer: 500
        case .succeeded: 300
        case .starting, .running: 200
        case .offline, .idle, .interrupted: 100
        }
    }
}

public enum AgentActivity: String, Codable, CaseIterable, Sendable {
    case thinking
    case reading
    case searching
    case editing
    case executing
    case testing
    case browsing
    case delegating
}

public enum TaskCapability: String, Codable, CaseIterable, Sendable {
    case approve
    case deny
    case answer
    case interrupt
    case retry
}

public struct TokenUsage: Codable, Equatable, Sendable {
    public var input: Int
    public var cachedInput: Int
    public var output: Int
    public var reasoningOutput: Int
    public var total: Int

    public init(
        input: Int = 0,
        cachedInput: Int = 0,
        output: Int = 0,
        reasoningOutput: Int = 0,
        total: Int = 0
    ) {
        self.input = input
        self.cachedInput = cachedInput
        self.output = output
        self.reasoningOutput = reasoningOutput
        self.total = total
    }
}

public struct SubagentSnapshot: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var path: String
    public var displayName: String
    public var lifecycle: AgentLifecycle
    public var activity: AgentActivity?
    /// 只存在内存和实时协议中，绝不写入任务快照文件。
    public var latestStep: String?
    public var tokenUsage: TokenUsage?
    public var startedAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        path: String,
        displayName: String? = nil,
        lifecycle: AgentLifecycle = .running,
        activity: AgentActivity? = .thinking,
        latestStep: String? = nil,
        tokenUsage: TokenUsage? = nil,
        startedAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.path = path
        self.displayName = displayName ?? Self.name(from: path)
        self.lifecycle = lifecycle
        self.activity = activity
        self.latestStep = latestStep
        self.tokenUsage = tokenUsage
        self.startedAt = startedAt
        self.updatedAt = updatedAt
    }

    public var isTerminal: Bool {
        [.succeeded, .interrupted].contains(lifecycle)
    }

    public func elapsed(at now: Date = .now) -> TimeInterval {
        max(0, (isTerminal ? updatedAt : now).timeIntervalSince(startedAt))
    }

    public static func name(from path: String) -> String {
        let raw = path
            .split(separator: "/")
            .last
            .map(String.init)?
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""
        guard let first = raw.first else {
            return "Codex 子代理"
        }
        return String(first).uppercased() + raw.dropFirst()
    }
}

public struct TaskSnapshot: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var source: AgentSource
    /// 兼容 Claude Code 协议的其他客户端（如 ZCode、WorkBuddy）的展示名。
    /// 线上 `source` 仍报 `claudeCode`，旧版手机端忽略该字段；`nil` 表示 Claude Code 本身。
    public var agentName: String?
    public var projectName: String
    public var title: String
    /// 最近一条用户消息，只存在内存和实时协议中，绝不写入任务快照文件。
    public var userPrompt: String?
    /// 只存在内存和实时协议中，绝不写入任务快照文件。
    public var latestStep: String?
    public var tokenUsage: TokenUsage?
    /// 子代理的名称、步骤和用量只存在内存和实时协议中。
    public var subagents: [SubagentSnapshot]
    public var lifecycle: AgentLifecycle
    public var activity: AgentActivity?
    public var startedAt: Date
    public var updatedAt: Date
    public var completedAt: Date?
    public var isUnread: Bool
    public var isPinned: Bool
    public var isMuted: Bool
    public var capabilities: Set<TaskCapability>

    public init(
        id: String,
        source: AgentSource,
        projectName: String,
        title: String? = nil,
        userPrompt: String? = nil,
        latestStep: String? = nil,
        tokenUsage: TokenUsage? = nil,
        subagents: [SubagentSnapshot] = [],
        lifecycle: AgentLifecycle,
        activity: AgentActivity? = nil,
        startedAt: Date = .now,
        updatedAt: Date = .now,
        completedAt: Date? = nil,
        isUnread: Bool = false,
        isPinned: Bool = false,
        isMuted: Bool = false,
        capabilities: Set<TaskCapability> = [],
        agentName: String? = nil
    ) {
        self.id = id
        self.source = source
        self.agentName = agentName
        self.projectName = projectName
        self.title = title ?? projectName
        self.userPrompt = userPrompt
        self.latestStep = latestStep
        self.tokenUsage = tokenUsage
        self.subagents = subagents
        self.lifecycle = lifecycle
        self.activity = activity
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
        self.isUnread = isUnread
        self.isPinned = isPinned
        self.isMuted = isMuted
        self.capabilities = capabilities
    }

    public var isTerminal: Bool {
        [.succeeded, .interrupted].contains(lifecycle)
    }

    public var effectivePriority: Int {
        var value = lifecycle.attentionPriority
        if isUnread && lifecycle == .succeeded {
            value += 50
        }
        if isPinned {
            value += 25
        }
        return value
    }
}

public struct UsageWindow: Identifiable, Codable, Equatable, Sendable {
    public var id: String { key }
    public var key: String
    public var label: String
    public var usedPercentage: Double
    public var remainingPercentage: Double
    public var windowMinutes: Int
    public var resetsAt: Date?

    public init(
        key: String,
        label: String,
        usedPercentage: Double,
        remainingPercentage: Double,
        windowMinutes: Int,
        resetsAt: Date?
    ) {
        self.key = key
        self.label = label
        self.usedPercentage = usedPercentage
        self.remainingPercentage = remainingPercentage
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
    }
}

public struct DailyUsagePoint: Identifiable, Codable, Equatable, Sendable {
    public var id: String { date }
    public var date: String
    public var inputTokens: Int64
    public var cachedInputTokens: Int64
    public var outputTokens: Int64
    public var reasoningOutputTokens: Int64
    public var totalTokens: Int64
    public var estimatedCostUSD: Double?

    public init(
        date: String,
        inputTokens: Int64 = 0,
        cachedInputTokens: Int64 = 0,
        outputTokens: Int64 = 0,
        reasoningOutputTokens: Int64 = 0,
        totalTokens: Int64 = 0,
        estimatedCostUSD: Double? = nil
    ) {
        self.date = date
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
        self.totalTokens = totalTokens
        self.estimatedCostUSD = estimatedCostUSD
    }
}

public struct UsageSnapshot: Codable, Equatable, Sendable {
    public var capturedAt: Date?
    public var planType: String?
    public var limitID: String?
    public var windows: [UsageWindow]
    public var dailyUsage: [DailyUsagePoint]

    public init(
        capturedAt: Date?,
        planType: String?,
        limitID: String?,
        windows: [UsageWindow],
        dailyUsage: [DailyUsagePoint] = []
    ) {
        self.capturedAt = capturedAt
        self.planType = planType
        self.limitID = limitID
        self.windows = windows
        self.dailyUsage = dailyUsage
    }
}

public enum ControlAction: String, Codable, Equatable, Sendable {
    case approve
    case deny
    case answer
    case interrupt
    case retry
    case mute
    case markRead
    case pin
}

public struct ControlPayload: Codable, Equatable, Sendable {
    public var taskID: String
    public var action: ControlAction
    public var value: String?

    public init(taskID: String, action: ControlAction, value: String? = nil) {
        self.taskID = taskID
        self.action = action
        self.value = value
    }
}

public enum ControlResult: String, Codable, Equatable, Sendable {
    case accepted
    case rejected
    case stale
    case unsupported
}
