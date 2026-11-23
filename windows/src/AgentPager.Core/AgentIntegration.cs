namespace AgentPager.Core;

/// <summary>配置文件的写法。</summary>
public enum IntegrationConfigFormat
{
    /// <summary>Claude Code 风格：{ "hooks": { 事件: [{ matcher?, hooks: [...] }] } }。</summary>
    ClaudeSettings,

    /// <summary>
    /// ZCode 风格：{ "hooks": { "enabled": bool, "events": { 事件: [{ hooks: [...] }] } } }。
    /// 事件名是严格白名单，出现白名单之外的事件会让 ZCode 丢弃整份 hooks 配置。
    /// </summary>
    ZcodeConfig,
}

/// <summary>适配依据，界面据此提示用户该适配的可信程度。</summary>
public enum IntegrationVerification
{
    /// <summary>依据客户端官方文档。</summary>
    OfficialDocs,

    /// <summary>仅依据 CodeIsland 等开源项目的实现，未在真机验证。</summary>
    CommunityImplementation,
}

/// <param name="Name">事件名。</param>
/// <param name="Matcher">工具名匹配；null 表示不写 matcher。</param>
/// <param name="Timeout">秒。仅需要长时间等待手机裁决的事件需要覆盖客户端默认值。</param>
public sealed record IntegrationHookEvent(string Name, string? Matcher = null, int? Timeout = null);

/// <summary>
/// 一个可接入 AgentPager 的第三方 Agent 客户端。Claude Code 与 Codex 有各自专用的安装器，
/// 这里登记的是 Hook 协议与 Claude Code 兼容（或相近）的其他客户端。
/// 新增客户端只需在 <see cref="AgentIntegrations.All"/> 加一条声明。
/// </summary>
/// <param name="Id"><c>--agent</c> 参数值，同时是线上与持久化里的稳定标识。</param>
/// <param name="ConfigPath">配置文件相对用户主目录的路径，使用 '/' 分隔。</param>
/// <param name="PresencePath">客户端数据目录（相对主目录）。不存在说明没装该客户端，此时不应凭空创建。</param>
/// <param name="RunsInBash">客户端在 Git Bash 里执行 Hook 命令，路径需要使用正斜杠。</param>
public sealed record AgentIntegration(
    string Id,
    string DisplayName,
    IntegrationConfigFormat Format,
    string ConfigPath,
    string PresencePath,
    IReadOnlyList<IntegrationHookEvent> Events,
    IntegrationVerification Verification,
    string? Note = null,
    bool RunsInBash = false)
{
    public string ConfigFile(string home) => Path.Combine(home, Path.Combine(ConfigPath.Split('/')));

    public string PresenceDirectory(string home) => Path.Combine(home, Path.Combine(PresencePath.Split('/')));

    /// <summary>界面展示用的配置路径，如 ~/.zcode/cli/config.json。</summary>
    public string DisplayConfigPath => "~/" + ConfigPath;

    /// <summary>
    /// Hook 命令：与 Claude Code 共用同一个 Bridge 可执行文件，
    /// <c>--source</c> 选择载荷解码器，<c>--agent</c> 标明具体客户端。
    /// </summary>
    public string HookCommand(string executablePath)
    {
        var path = RunsInBash ? executablePath.Replace('\\', '/') : executablePath;
        return $"\"{path}\" --hook --source claude --agent {Id}";
    }
}

public static class AgentIntegrations
{
    /// <summary>Claude Code 全套事件中，这些客户端都认识的保守子集。</summary>
    private static readonly IntegrationHookEvent[] BaseClaudeEvents =
    [
        new("SessionStart"),
        new("SessionEnd"),
        new("UserPromptSubmit"),
        new("Stop"),
        new("SubagentStart"),
        new("SubagentStop"),
        new("Notification", "*"),
        new("PreToolUse", "*"),
        new("PostToolUse", "*"),
        new("PreCompact"),
    ];

    /// <summary>在保守子集上增加工具失败与权限请求；权限请求要等手机裁决，需要长超时。</summary>
    private static readonly IntegrationHookEvent[] ApprovalCapableClaudeEvents =
    [
        .. BaseClaudeEvents,
        new("PostToolUseFailure", "*"),
        new("PermissionRequest", "*", 86_400),
    ];

    /// <summary>ZCode 的严格 7 事件白名单。</summary>
    private static readonly IntegrationHookEvent[] ZcodeEvents =
    [
        new("SessionStart"),
        new("UserPromptSubmit"),
        new("PreToolUse"),
        new("PermissionRequest", Timeout: 86_400),
        new("PostToolUse"),
        new("PostToolUseFailure"),
        new("Stop"),
    ];

    public static IReadOnlyList<AgentIntegration> All { get; } =
    [
        new("zcode", "ZCode", IntegrationConfigFormat.ZcodeConfig,
            ".zcode/cli/config.json", ".zcode", ZcodeEvents,
            IntegrationVerification.CommunityImplementation,
            "ZCode 不支持热加载，安装或卸载后需要重启 ZCode。"),
        new("codebuddy", "CodeBuddy", IntegrationConfigFormat.ClaudeSettings,
            ".codebuddy/settings.json", ".codebuddy", ApprovalCapableClaudeEvents,
            IntegrationVerification.OfficialDocs,
            "CodeBuddy 在 Windows 上通过 Git Bash 执行 Hook，需要先安装 Git for Windows。",
            RunsInBash: true),
        new("workbuddy", "WorkBuddy", IntegrationConfigFormat.ClaudeSettings,
            ".workbuddy/settings.json", ".workbuddy", ApprovalCapableClaudeEvents,
            IntegrationVerification.CommunityImplementation,
            "WorkBuddy 桌面端的配置路径尚未在真机确认；若无效，请改用 CodeBuddy。",
            RunsInBash: true),
        new("qoder", "Qoder", IntegrationConfigFormat.ClaudeSettings,
            ".qoder/settings.json", ".qoder", ApprovalCapableClaudeEvents,
            IntegrationVerification.CommunityImplementation),
        new("qoderwork", "QoderWork", IntegrationConfigFormat.ClaudeSettings,
            ".qoderwork/settings.json", ".qoderwork", ApprovalCapableClaudeEvents,
            IntegrationVerification.CommunityImplementation,
            "QoderWork 不支持热加载，安装或卸载后需要重启 QoderWork。"),
        new("droid", "Factory", IntegrationConfigFormat.ClaudeSettings,
            ".factory/settings.json", ".factory", BaseClaudeEvents,
            IntegrationVerification.CommunityImplementation),
        new("stepfun", "StepFun", IntegrationConfigFormat.ClaudeSettings,
            ".stepfun/settings.json", ".stepfun", BaseClaudeEvents,
            IntegrationVerification.CommunityImplementation),
    ];

    public static AgentIntegration? Find(string? id) =>
        id is null ? null : All.FirstOrDefault(value => value.Id == id);

    /// <summary>任务卡片上展示的客户端名；null 表示 Claude Code 本身或未知来源。</summary>
    public static string? DisplayNameFor(string? id) => Find(id)?.DisplayName;
}
