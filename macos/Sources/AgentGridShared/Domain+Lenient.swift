import Foundation

// 新版 Bridge 可能增加未知枚举值或字段缺省。手机端宁可丢掉无法识别的单个任务/能力，
// 也不能让整条快照解码失败而清空界面（Android 端同样如此）。

/// 逐项解码数组，跳过无法解码的元素。
struct LossyArray<Element: Decodable>: Decodable {
    var elements: [Element]

    private struct Discard: Decodable {}

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var result: [Element] = []
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                result.append(element)
            } else {
                _ = try? container.decode(Discard.self)
            }
        }
        elements = result
    }
}

extension TokenUsage {
    private enum LenientKeys: String, CodingKey {
        case input, cachedInput, output, reasoningOutput, total
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: LenientKeys.self)
        self.init(
            input: try container.decodeIfPresent(Int.self, forKey: .input) ?? 0,
            cachedInput: try container.decodeIfPresent(Int.self, forKey: .cachedInput) ?? 0,
            output: try container.decodeIfPresent(Int.self, forKey: .output) ?? 0,
            reasoningOutput: try container.decodeIfPresent(Int.self, forKey: .reasoningOutput) ?? 0,
            total: try container.decodeIfPresent(Int.self, forKey: .total) ?? 0
        )
    }
}

extension SubagentSnapshot {
    private enum LenientKeys: String, CodingKey {
        case id, path, displayName, lifecycle, activity, latestStep, tokenUsage, startedAt, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: LenientKeys.self)
        let path = try container.decode(String.self, forKey: .path)
        id = try container.decode(String.self, forKey: .id)
        self.path = path
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
            ?? Self.name(from: path)
        lifecycle = (try? container.decode(AgentLifecycle.self, forKey: .lifecycle)) ?? .running
        activity = try? container.decodeIfPresent(AgentActivity.self, forKey: .activity)
        latestStep = try container.decodeIfPresent(String.self, forKey: .latestStep)
        tokenUsage = try? container.decodeIfPresent(TokenUsage.self, forKey: .tokenUsage)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }
}

extension TaskSnapshot {
    private enum LenientKeys: String, CodingKey {
        case id, source, agentName, projectName, title, userPrompt, latestStep, tokenUsage
        case subagents, lifecycle, activity, startedAt, updatedAt, completedAt
        case isUnread, isPinned, isMuted, capabilities
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: LenientKeys.self)
        let projectName = try container.decode(String.self, forKey: .projectName)
        id = try container.decode(String.self, forKey: .id)
        source = try container.decode(AgentSource.self, forKey: .source)
        agentName = try container.decodeIfPresent(String.self, forKey: .agentName)
        self.projectName = projectName
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? projectName
        userPrompt = try container.decodeIfPresent(String.self, forKey: .userPrompt)
        latestStep = try container.decodeIfPresent(String.self, forKey: .latestStep)
        tokenUsage = try? container.decodeIfPresent(TokenUsage.self, forKey: .tokenUsage)
        subagents = (try? container.decodeIfPresent(LossyArray<SubagentSnapshot>.self, forKey: .subagents))?
            .elements ?? []
        lifecycle = try container.decode(AgentLifecycle.self, forKey: .lifecycle)
        // 未知的活动只影响动画与文案，回退为 nil 即可。
        activity = try? container.decodeIfPresent(AgentActivity.self, forKey: .activity)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        isUnread = try container.decodeIfPresent(Bool.self, forKey: .isUnread) ?? false
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        isMuted = try container.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        let capabilityNames = (try? container.decodeIfPresent([String].self, forKey: .capabilities)) ?? []
        capabilities = Set(capabilityNames.compactMap(TaskCapability.init(rawValue:)))
    }
}

extension PendingRequest {
    private enum LenientKeys: String, CodingKey {
        case taskID, kind, summary, options
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: LenientKeys.self)
        self.init(
            taskID: try container.decode(String.self, forKey: .taskID),
            kind: try container.decode(PendingRequestKind.self, forKey: .kind),
            summary: try container.decodeIfPresent(String.self, forKey: .summary),
            options: try container.decodeIfPresent([String].self, forKey: .options) ?? []
        )
    }
}

extension StateSnapshotPayload {
    private enum LenientKeys: String, CodingKey {
        case tasks, usage, claudeUsage, focusedTaskID, pendingRequests
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: LenientKeys.self)
        let tasks = (try? container.decodeIfPresent(LossyArray<TaskSnapshot>.self, forKey: .tasks))?
            .elements ?? []
        let pending = (try? container.decodeIfPresent(LossyArray<PendingRequest>.self, forKey: .pendingRequests))?
            .elements ?? []
        self.init(
            tasks: tasks,
            usage: try? container.decodeIfPresent(UsageSnapshot.self, forKey: .usage),
            claudeUsage: try? container.decodeIfPresent(UsageSnapshot.self, forKey: .claudeUsage),
            focusedTaskID: try container.decodeIfPresent(String.self, forKey: .focusedTaskID),
            pendingRequests: pending
        )
    }
}
