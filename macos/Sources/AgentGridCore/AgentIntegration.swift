import Foundation

/// 一个可接入 AgentPager 的第三方 Agent 客户端。
///
/// Claude Code 与 Codex 有各自专用的安装器，不在此列；这里登记的是 Hook 协议
/// 与 Claude Code 兼容（或相近）的其他客户端。新增客户端只需在
/// `AgentIntegrations.all` 加一条声明，安装、卸载、检测与界面都由声明驱动。
public struct AgentIntegration: Identifiable, Equatable, Sendable {
    /// 配置文件的写法。
    public enum ConfigFormat: Equatable, Sendable {
        /// Claude Code 风格：`{ "hooks": { 事件: [{ matcher?, hooks: [...] }] } }`。
        case claudeSettings
        /// ZCode 风格：`{ "hooks": { "enabled": Bool, "events": { 事件: [{ hooks: [...] }] } } }`，
        /// 事件名是严格白名单，出现任何白名单之外的事件会让 ZCode 丢弃整份 hooks 配置。
        case zcodeConfig
    }

    /// 适配依据，界面据此提示用户该适配的可信程度。
    public enum Verification: Equatable, Sendable {
        /// 依据客户端官方文档。
        case officialDocs
        /// 仅依据 CodeIsland 等开源项目的实现，未在真机验证。
        case communityImplementation
    }

    public struct HookEvent: Equatable, Sendable {
        public var name: String
        public var matcher: String?
        /// 秒。仅权限请求这类需要长时间等待手机裁决的事件需要覆盖客户端默认值。
        public var timeout: Int?

        public init(_ name: String, matcher: String? = nil, timeout: Int? = nil) {
            self.name = name
            self.matcher = matcher
            self.timeout = timeout
        }
    }

    /// `--agent` 参数值，同时是线上与持久化里的稳定标识。
    public let id: String
    public let displayName: String
    public let format: ConfigFormat
    /// 配置文件相对用户主目录的路径。
    public let configPath: String
    /// 客户端的数据目录（相对主目录）。目录不存在说明没装该客户端，此时不应凭空创建。
    public let presencePath: String
    public let events: [HookEvent]
    public let verification: Verification
    /// 给用户的补充说明（例如是否需要重启客户端）。
    public let note: String?

    public init(
        id: String,
        displayName: String,
        format: ConfigFormat = .claudeSettings,
        configPath: String,
        presencePath: String,
        events: [HookEvent],
        verification: Verification,
        note: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.format = format
        self.configPath = configPath
        self.presencePath = presencePath
        self.events = events
        self.verification = verification
        self.note = note
    }

    public func configURL(home: URL) -> URL {
        home.appendingPathComponent(configPath)
    }

    public func presenceURL(home: URL) -> URL {
        home.appendingPathComponent(presencePath, isDirectory: true)
    }

    /// Hook 命令：与 Claude Code 共用同一个 `AgentPagerHooks` 二进制，
    /// `--source` 选择载荷解码器，`--agent` 标明具体客户端。
    public func hookCommand(for binaryPath: String) -> String {
        "\(Self.shellQuote(binaryPath)) --source claude --agent \(id)"
    }

    static func shellQuote(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }
        return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

public enum AgentIntegrations {
    /// Claude Code 全套事件中，这些客户端都认识的保守子集。
    private static let baseClaudeEvents: [AgentIntegration.HookEvent] = [
        .init("SessionStart"),
        .init("SessionEnd"),
        .init("UserPromptSubmit"),
        .init("Stop"),
        .init("SubagentStart"),
        .init("SubagentStop"),
        .init("Notification", matcher: "*"),
        .init("PreToolUse", matcher: "*"),
        .init("PostToolUse", matcher: "*"),
        .init("PreCompact"),
    ]

    /// 在保守子集上增加工具失败与权限请求；权限请求要等手机裁决，需要长超时。
    private static let approvalCapableClaudeEvents: [AgentIntegration.HookEvent] =
        baseClaudeEvents + [
            .init("PostToolUseFailure", matcher: "*"),
            .init("PermissionRequest", matcher: "*", timeout: 86_400),
        ]

    /// ZCode 的严格 7 事件白名单。
    private static let zcodeEvents: [AgentIntegration.HookEvent] = [
        .init("SessionStart"),
        .init("UserPromptSubmit"),
        .init("PreToolUse"),
        .init("PermissionRequest", timeout: 86_400),
        .init("PostToolUse"),
        .init("PostToolUseFailure"),
        .init("Stop"),
    ]

    public static let all: [AgentIntegration] = [
        AgentIntegration(
            id: "zcode",
            displayName: "ZCode",
            format: .zcodeConfig,
            configPath: ".zcode/cli/config.json",
            presencePath: ".zcode",
            events: zcodeEvents,
            verification: .communityImplementation,
            note: "ZCode 不支持热加载，安装或卸载后需要重启 ZCode。"
        ),
        AgentIntegration(
            id: "codebuddy",
            displayName: "CodeBuddy",
            configPath: ".codebuddy/settings.json",
            presencePath: ".codebuddy",
            events: approvalCapableClaudeEvents,
            verification: .officialDocs
        ),
        AgentIntegration(
            id: "workbuddy",
            displayName: "WorkBuddy",
            configPath: ".workbuddy/settings.json",
            presencePath: ".workbuddy",
            events: approvalCapableClaudeEvents,
            verification: .communityImplementation,
            note: "WorkBuddy 桌面端的配置路径尚未在真机确认；若无效，请改用 CodeBuddy。"
        ),
        AgentIntegration(
            id: "qoder",
            displayName: "Qoder",
            configPath: ".qoder/settings.json",
            presencePath: ".qoder",
            events: approvalCapableClaudeEvents,
            verification: .communityImplementation
        ),
        AgentIntegration(
            id: "qoderwork",
            displayName: "QoderWork",
            configPath: ".qoderwork/settings.json",
            presencePath: ".qoderwork",
            events: approvalCapableClaudeEvents,
            verification: .communityImplementation,
            note: "QoderWork 不支持热加载，安装或卸载后需要重启 QoderWork。"
        ),
        AgentIntegration(
            id: "droid",
            displayName: "Factory",
            configPath: ".factory/settings.json",
            presencePath: ".factory",
            events: baseClaudeEvents,
            verification: .communityImplementation
        ),
        AgentIntegration(
            id: "stepfun",
            displayName: "StepFun",
            configPath: ".stepfun/settings.json",
            presencePath: ".stepfun",
            events: baseClaudeEvents,
            verification: .communityImplementation
        ),
    ]

    public static func integration(id: String?) -> AgentIntegration? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }

    /// 任务卡片上展示的客户端名；`nil` 表示 Claude Code 本身或未知来源。
    public static func displayName(forAgentID id: String?) -> String? {
        integration(id: id)?.displayName
    }
}
