import Foundation

public enum CodexHookEventName: String, Codable, Sendable {
    case sessionStart = "SessionStart"
    case preToolUse = "PreToolUse"
    case permissionRequest = "PermissionRequest"
    case postToolUse = "PostToolUse"
    case userPromptSubmit = "UserPromptSubmit"
    case stop = "Stop"
}

public enum HookJSONValue: Equatable, Codable, Sendable {
    case string(String)
    case number(Double)
    case boolean(Bool)
    case object([String: HookJSONValue])
    case array([HookJSONValue])
    case null

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: HookJSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([HookJSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "不支持的 Hook JSON 值"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .boolean(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    fileprivate var displayText: String? {
        switch self {
        case let .string(value):
            value
        case let .array(values):
            values.compactMap(\.displayText).joined(separator: " ")
        default:
            nil
        }
    }
}

public struct HookToolInput: Equatable, Codable, Sendable {
    public var cmd: HookJSONValue?
    public var command: HookJSONValue?
    public var description: String?

    public init(
        cmd: HookJSONValue? = nil,
        command: HookJSONValue? = nil,
        description: String? = nil
    ) {
        self.cmd = cmd
        self.command = command
        self.description = description
    }

    public var summary: String? {
        cmd?.displayText ?? command?.displayText ?? description
    }
}

public struct CodexHookPayload: Codable, Equatable, Sendable {
    public var cwd: String
    public var hookEventName: CodexHookEventName
    public var sessionID: String
    public var source: String?
    public var turnID: String?
    public var transcriptPath: String?
    public var toolName: String?
    public var toolUseID: String?
    public var toolInput: HookToolInput?
    public var prompt: String?
    public var model: String?

    private enum CodingKeys: String, CodingKey {
        case cwd
        case hookEventName = "hook_event_name"
        case sessionID = "session_id"
        case source
        case turnID = "turn_id"
        case transcriptPath = "transcript_path"
        case toolName = "tool_name"
        case toolUseID = "tool_use_id"
        case toolInput = "tool_input"
        case prompt
        case model
    }

    public init(
        cwd: String,
        hookEventName: CodexHookEventName,
        sessionID: String,
        source: String? = nil,
        turnID: String? = nil,
        transcriptPath: String? = nil,
        toolName: String? = nil,
        toolUseID: String? = nil,
        toolInput: HookToolInput? = nil,
        prompt: String? = nil,
        model: String? = nil
    ) {
        self.cwd = cwd
        self.hookEventName = hookEventName
        self.sessionID = sessionID
        self.source = source
        self.turnID = turnID
        self.transcriptPath = transcriptPath
        self.toolName = toolName
        self.toolUseID = toolUseID
        self.toolInput = toolInput
        self.prompt = prompt
        self.model = model
    }

    public var projectName: String {
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        return name.isEmpty ? "Codex" : name
    }
}

public enum CodexPermissionDecision: String, Codable, Equatable, Sendable {
    case allow
    case deny
}

public enum CodexHookOutput {
    private struct PermissionResponse: Encodable {
        var hookSpecificOutput: SpecificOutput

        struct SpecificOutput: Encodable {
            var hookEventName = CodexHookEventName.permissionRequest
            var decision: Decision
        }

        struct Decision: Encodable {
            var behavior: CodexPermissionDecision
        }
    }

    public static func permission(_ decision: CodexPermissionDecision) throws -> Data {
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

public struct HookFileMutation: Sendable {
    public var contents: Data?
    public var changed: Bool
    public var hasRemainingHooks: Bool
}

public enum CodexHookInstaller {
    public static let managedStatusMessage = "Managed by AgentPager"
    private static let legacyManagedStatusMessage = "Managed by AgentGrid"
    public static let hookEvents: [(name: String, matcher: String?, timeout: Int)] = [
        ("SessionStart", "startup|resume", 45),
        ("UserPromptSubmit", nil, 45),
        ("PreToolUse", nil, 45),
        ("PostToolUse", nil, 45),
        ("PermissionRequest", nil, 3_600),
        ("Stop", nil, 45),
    ]

    public static func install(existingData: Data?, command: String) throws -> HookFileMutation {
        var root = try rootObject(existingData)
        var hooks = root["hooks"] as? [String: Any] ?? [:]

        for spec in hookEvents {
            let groups = (hooks[spec.name] as? [[String: Any]] ?? [])
                .filter { !isManaged($0) }
            hooks[spec.name] = groups + [
                managedGroup(spec: spec, command: command),
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

    public static func uninstall(existingData: Data?) throws -> HookFileMutation {
        guard let existingData else {
            return HookFileMutation(contents: nil, changed: false, hasRemainingHooks: false)
        }
        var root = try rootObject(existingData)
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        var changed = false

        for spec in hookEvents {
            let groups = hooks[spec.name] as? [[String: Any]] ?? []
            let remaining = groups.filter { !isManaged($0) }
            changed = changed || remaining.count != groups.count
            if remaining.isEmpty {
                hooks.removeValue(forKey: spec.name)
            } else {
                hooks[spec.name] = remaining
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

    public static func isInstalled(data: Data?) -> Bool {
        guard let root = try? rootObject(data),
              let hooks = root["hooks"] as? [String: Any] else {
            return false
        }
        return hookEvents.allSatisfy { spec in
            (hooks[spec.name] as? [[String: Any]] ?? []).contains(where: isManaged)
        }
    }

    private static func managedGroup(
        spec: (name: String, matcher: String?, timeout: Int),
        command: String
    ) -> [String: Any] {
        var group: [String: Any] = [
            "hooks": [[
                "type": "command",
                "command": shellQuote(command),
                "timeout": spec.timeout,
                "statusMessage": managedStatusMessage,
            ]],
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
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
