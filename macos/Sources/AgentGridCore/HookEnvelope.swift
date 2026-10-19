import Foundation

/// 标记 Hook 载荷来源，用于在桥接服务器与权限裁决间区分 Codex / Claude。
public enum HookSource: String, Codable, Sendable, Equatable {
    case codex
    case claude
}

/// Hook CLI 与 `HookBridgeServer` 之间的传输信封。
///
/// 同一个 `AgentPagerHooks` 二进制同时服务 Codex 与 Claude Code，通过
/// `--source` 区分，再把原始载荷包进信封送给桥接服务器，使服务器能选择
/// 正确的解码器与响应格式。
public struct HookEnvelopePayload: Codable, Equatable, Sendable {
    public var hookSource: HookSource
    /// 具体客户端标识（`--agent`）。旧版 Hook 不带该字段，视为来源本身（Codex / Claude Code）。
    public var agentID: String?
    /// 原始 Hook 载荷（Codex 或 Claude），以未类型化 JSON 携带，由服务器按来源解码。
    public var payload: [String: AnyCodable]

    public init(hookSource: HookSource, agentID: String? = nil, payload: [String: AnyCodable]) {
        self.hookSource = hookSource
        self.agentID = agentID
        self.payload = payload
    }

    private enum CodingKeys: String, CodingKey {
        case hookSource = "hook_source"
        case agentID = "agent_id"
        case payload
    }
}

/// 包装任意 JSON 值的 Codable 容器，用于信封透传原始载荷。
public enum AnyCodable: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case boolean(Bool)
    case object([String: AnyCodable])
    case array([AnyCodable])
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
        } else if let value = try? container.decode([String: AnyCodable].self) {
            self = .object(value)
        } else if let value = try? container.decode([AnyCodable].self) {
            self = .array(value)
        } else {
            self = .null
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
}
