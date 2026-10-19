import Foundation

/// Claude Code 的生命周期 Hook 事件名。
///
/// 仅枚举 AgentPager 关心的事件；Claude 未来新增的事件会以原始字符串形式保留在
/// `ClaudeHookPayload.hookEventName` 中，解码不会失败。
public enum ClaudeHookEvent: String, Codable, Sendable {
    case sessionStart = "SessionStart"
    case sessionEnd = "SessionEnd"
    case userPromptSubmit = "UserPromptSubmit"
    case preToolUse = "PreToolUse"
    case postToolUse = "PostToolUse"
    case postToolUseFailure = "PostToolUseFailure"
    case permissionRequest = "PermissionRequest"
    case permissionDenied = "PermissionDenied"
    case notification = "Notification"
    case stop = "Stop"
    case stopFailure = "StopFailure"
    case subagentStart = "SubagentStart"
    case subagentStop = "SubagentStop"
    case preCompact = "PreCompact"
}

public enum ClaudeSessionStartSource: String, Codable, Sendable {
    case startup
    case resume
    case clear
    case compact
}

/// Claude Code 通过 stdin 传给 Hook 的载荷。
///
/// 字段命名与 Claude Code 官方 Hook 协议一致（snake_case），
/// 仅解码 AgentPager 需要的子集，其余字段被忽略，向前兼容。
public struct ClaudeHookPayload: Codable, Equatable, Sendable {
    public var cwd: String
    public var hookEventName: String
    public var sessionID: String
    public var transcriptPath: String?
    public var permissionMode: String?
    public var toolName: String?
    public var toolUseID: String?
    public var toolInput: HookJSONValue?
    public var prompt: String?
    public var model: String?
    public var source: String?
    public var message: String?
    public var title: String?
    public var notificationType: String?
    public var subtype: String?
    public var stopHookActive: Bool?
    public var lastAssistantMessage: String?
    /// 子代理事件（SubagentStart/SubagentStop）携带的子代理标识与类型。
    public var agentID: String?
    public var agentType: String?
    public var taskDescription: String?
    /// 具体客户端的 `AgentIntegration.id`（如 zcode、workbuddy）；`nil` 表示 Claude Code 本身。
    /// 不来自客户端载荷，由 Hook 命令行的 `--agent` 经信封传入，因此不参与编解码。
    public var integrationID: String?

    private enum CodingKeys: String, CodingKey {
        case cwd
        case hookEventName = "hook_event_name"
        case sessionID = "session_id"
        case transcriptPath = "transcript_path"
        case permissionMode = "permission_mode"
        case toolName = "tool_name"
        case toolUseID = "tool_use_id"
        case toolInput = "tool_input"
        case prompt
        case model
        case source
        case message
        case title
        case notificationType = "notification_type"
        case subtype
        case stopHookActive = "stop_hook_active"
        case lastAssistantMessage = "last_assistant_message"
        case agentID = "agent_id"
        case agentType = "agent_type"
        case taskDescription = "task_description"
    }

    public init(
        cwd: String,
        hookEventName: String,
        sessionID: String,
        transcriptPath: String? = nil,
        permissionMode: String? = nil,
        toolName: String? = nil,
        toolUseID: String? = nil,
        toolInput: HookJSONValue? = nil,
        prompt: String? = nil,
        model: String? = nil,
        source: String? = nil,
        message: String? = nil,
        title: String? = nil,
        notificationType: String? = nil,
        subtype: String? = nil,
        stopHookActive: Bool? = nil,
        lastAssistantMessage: String? = nil,
        agentID: String? = nil,
        agentType: String? = nil,
        taskDescription: String? = nil
    ) {
        self.cwd = cwd
        self.hookEventName = hookEventName
        self.sessionID = sessionID
        self.transcriptPath = transcriptPath
        self.permissionMode = permissionMode
        self.toolName = toolName
        self.toolUseID = toolUseID
        self.toolInput = toolInput
        self.prompt = prompt
        self.model = model
        self.source = source
        self.message = message
        self.title = title
        self.notificationType = notificationType
        self.subtype = subtype
        self.stopHookActive = stopHookActive
        self.lastAssistantMessage = lastAssistantMessage
        self.agentID = agentID
        self.agentType = agentType
        self.taskDescription = taskDescription
    }

    public var event: ClaudeHookEvent? {
        ClaudeHookEvent(rawValue: hookEventName)
    }

    public var projectName: String {
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        return name.isEmpty ? "Claude Code" : name
    }
}

/// AgentPager 对 Claude Code 权限请求给出的裁决，映射到 Claude 的
/// `hookSpecificOutput.permissionRequest.decision.behavior`。
public enum ClaudePermissionDecision: String, Codable, Equatable, Sendable {
    case allow
    case deny
}

/// 生成 Claude Code 期望的 Hook stdout 响应。
///
/// 非权限事件不需要任何输出（Claude 视空输出为继续执行）；
/// `PermissionRequest` 必须返回带 `hookSpecificOutput` 的 JSON。
public enum ClaudeHookOutput {
    private struct PermissionResponse: Encodable {
        var `continue` = true
        var suppressOutput = true
        var hookSpecificOutput: SpecificOutput

        struct SpecificOutput: Encodable {
            var hookEventName = ClaudeHookEvent.permissionRequest.rawValue
            var decision: Decision
        }

        struct Decision: Encodable {
            var behavior: ClaudePermissionDecision
        }
    }

    public static func permission(_ decision: ClaudePermissionDecision) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(
            PermissionResponse(
                hookSpecificOutput: .init(
                    decision: .init(behavior: decision)
                )
            )
        )
        data.append(UInt8(ascii: "\n"))
        return data
    }
}

/// 写入 `~/.claude/settings.json` 的 Hook 安装器。
///
/// 设计与 `CodexHookInstaller` 一致：保留用户既有 Hook，仅替换 AgentPager
/// 管理项，并在改写前由 `ClaudeHookConfiguration` 备份。事件规格覆盖
/// Claude Code 全部生命周期事件，`PermissionRequest` 使用 24 小时超时以
/// 等待用户在手机上批准。
public enum ClaudeHookInstaller {
    public static let managedStatusMessage = "Managed by AgentPager (Claude Code)"
    private static let legacyManagedStatusMessage = "Managed by AgentGrid (Claude Code)"

    /// (事件名, matcher, timeout 秒)。timeout 仅用于需要长等待的权限事件。
    public static let hookEvents: [(name: String, matcher: String?, timeout: Int?)] = [
        ("SessionStart", nil, nil),
        ("SessionEnd", nil, nil),
        ("UserPromptSubmit", nil, nil),
        ("Stop", nil, nil),
        ("StopFailure", nil, nil),
        ("SubagentStart", nil, nil),
        ("SubagentStop", nil, nil),
        ("Notification", "*", nil),
        ("PreToolUse", "*", nil),
        ("PermissionRequest", "*", 86_400),
        ("PostToolUse", "*", nil),
        ("PostToolUseFailure", "*", nil),
        ("PermissionDenied", "*", nil),
        ("PreCompact", nil, nil),
    ]

    /// Hook 调用命令：`'<binary>' --source claude`。
    public static func hookCommand(for binaryPath: String) -> String {
        "\(shellQuote(binaryPath)) --source claude"
    }

    public typealias EventSpec = (name: String, matcher: String?, timeout: Int?)

    /// 兼容客户端（`AgentIntegration`）使用自己的事件集合与状态文案安装同一种 Hook 结构。
    public static func install(
        existingData: Data?,
        command: String,
        events: [EventSpec]? = nil,
        statusMessage: String? = nil
    ) throws -> HookFileMutation {
        let events = events ?? hookEvents
        let statusMessage = statusMessage ?? managedStatusMessage
        var root = try rootObject(existingData)
        var hooks = root["hooks"] as? [String: Any] ?? [:]

        // 先清理任何已存在的 AgentPager 管理项，保证幂等替换而非叠加。
        for spec in events {
            let groups = (hooks[spec.name] as? [[String: Any]] ?? [])
                .filter { !isManaged($0) }
            if groups.isEmpty {
                hooks.removeValue(forKey: spec.name)
            } else {
                hooks[spec.name] = groups
            }
        }

        for spec in events {
            let groups = (hooks[spec.name] as? [[String: Any]] ?? [])
                .filter { !isManaged($0) }
            hooks[spec.name] = groups + [
                managedGroup(spec: spec, command: command, statusMessage: statusMessage),
            ]
        }

        root["hooks"] = hooks
        let data = try serialize(root)
        return HookFileMutation(
            contents: data,
            changed: data != existingData,
            hasRemainingHooks: true
        )
    }

    public static func uninstall(
        existingData: Data?,
        events: [EventSpec]? = nil
    ) throws -> HookFileMutation {
        let events = events ?? hookEvents
        guard let existingData else {
            return HookFileMutation(contents: nil, changed: false, hasRemainingHooks: false)
        }
        var root = try rootObject(existingData)
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        var changed = false

        // 同时清理配置里任何事件下遗留的管理项（旧版本可能装过现在已不再使用的事件）。
        for name in Set(events.map(\.name)).union(hooks.keys) {
            guard let groups = hooks[name] as? [[String: Any]] else { continue }
            let remaining = groups.filter { !isManaged($0) }
            changed = changed || remaining.count != groups.count
            if remaining.isEmpty {
                hooks.removeValue(forKey: name)
            } else {
                hooks[name] = remaining
            }
        }

        if hooks.isEmpty {
            root.removeValue(forKey: "hooks")
        } else {
            root["hooks"] = hooks
        }

        if root.isEmpty {
            return HookFileMutation(
                contents: nil,
                changed: changed,
                hasRemainingHooks: false
            )
        }
        let data = try serialize(root)
        return HookFileMutation(
            contents: data,
            changed: changed,
            hasRemainingHooks: !hooks.isEmpty
        )
    }

    public static func isInstalled(data: Data?, events: [EventSpec]? = nil) -> Bool {
        guard let root = try? rootObject(data),
              let hooks = root["hooks"] as? [String: Any] else {
            return false
        }
        return (events ?? hookEvents).allSatisfy { spec in
            (hooks[spec.name] as? [[String: Any]] ?? []).contains(where: isManaged)
        }
    }

    private static func managedGroup(
        spec: (name: String, matcher: String?, timeout: Int?),
        command: String,
        statusMessage: String
    ) -> [String: Any] {
        var hook: [String: Any] = [
            "type": "command",
            "command": command,
            "statusMessage": statusMessage,
        ]
        if let timeout = spec.timeout {
            hook["timeout"] = timeout
        }

        var group: [String: Any] = [
            "hooks": [hook],
        ]
        if let matcher = spec.matcher {
            group["matcher"] = matcher
        }
        return group
    }

    private static func isManaged(_ group: [String: Any]) -> Bool {
        guard let hooks = group["hooks"] as? [[String: Any]] else {
            return false
        }
        return hooks.contains {
            let statusMessage = $0["statusMessage"] as? String
            let command = $0["command"] as? String
            return statusMessage == managedStatusMessage
                || statusMessage == legacyManagedStatusMessage
                || command?.contains("AgentPagerHooks") == true
                || command?.contains("AgentGridHooks") == true
        }
    }

    private static func rootObject(_ data: Data?) throws -> [String: Any] {
        guard let data, !data.isEmpty else { return [:] }
        let value = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = value as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return dictionary
    }

    private static func serialize(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
    }

    private static func shellQuote(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }
        return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
