using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;

namespace AgentPager.Core;

/// <summary>
/// Claude Code 通过 stdin 传给 Hook 的载荷。事件名以字符串保留，向前兼容
/// Claude 未来新增的事件。字段命名与官方 Hook 协议一致（snake_case）。
/// </summary>
public sealed record ClaudeHookPayload(
    string Cwd,
    [property: JsonPropertyName("hook_event_name")] string HookEventName,
    [property: JsonPropertyName("session_id")] string SessionID,
    [property: JsonPropertyName("transcript_path")] string? TranscriptPath = null,
    [property: JsonPropertyName("permission_mode")] string? PermissionMode = null,
    [property: JsonPropertyName("tool_name")] string? ToolName = null,
    [property: JsonPropertyName("tool_use_id")] string? ToolUseID = null,
    [property: JsonPropertyName("tool_input")] JsonElement? ToolInput = null,
    string? Prompt = null,
    string? Model = null,
    string? Source = null,
    string? Message = null,
    string? Title = null,
    [property: JsonPropertyName("notification_type")] string? NotificationType = null,
    string? Subtype = null,
    [property: JsonPropertyName("stop_hook_active")] bool? StopHookActive = null,
    [property: JsonPropertyName("last_assistant_message")] string? LastAssistantMessage = null,
    [property: JsonPropertyName("agent_id")] string? AgentID = null,
    [property: JsonPropertyName("agent_type")] string? AgentType = null,
    [property: JsonPropertyName("task_description")] string? TaskDescription = null)
{
    /// <summary>
    /// 具体客户端的 <see cref="AgentIntegration.Id"/>（如 zcode、workbuddy）；null 表示 Claude Code 本身。
    /// 不来自客户端载荷，由 Hook 命令行的 --agent 经信封传入，因此不参与序列化。
    /// </summary>
    [JsonIgnore]
    public string? IntegrationID { get; init; }

    [JsonIgnore]
    public string ProjectName =>
        Path.GetFileName(Cwd.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar)) is { Length: > 0 } value
            ? value
            : "Claude Code";
}

public enum ClaudePermissionDecision { Allow, Deny }

/// <summary>
/// 生成 Claude Code 期望的 Hook stdout 响应。非权限事件不需要输出；
/// PermissionRequest 必须返回带 hookSpecificOutput 的 JSON。
/// </summary>
public static class ClaudeHookOutput
{
    public static byte[] Permission(ClaudePermissionDecision decision)
    {
        var value = new
        {
            @continue = true,
            suppressOutput = true,
            hookSpecificOutput = new
            {
                hookEventName = "PermissionRequest",
                decision = new { behavior = decision == ClaudePermissionDecision.Allow ? "allow" : "deny" },
            },
        };
        return System.Text.Encoding.UTF8.GetBytes(JsonSerializer.Serialize(value) + "\n");
    }
}

public enum HookSource { Codex, Claude }

/// <summary>桥接服务器收到并已分类的 Hook 事件。</summary>
public abstract record HookEnvelope
{
    public sealed record Codex(CodexHookPayload Hook) : HookEnvelope;
    public sealed record Claude(ClaudeHookPayload Hook) : HookEnvelope;
}

/// <summary>
/// 写入 ~/.claude/settings.json 的 Hook 安装器，结构与 CodexHookInstaller 对齐：
/// 保留用户既有 Hook、幂等替换管理项、卸载只删除管理项。
/// 覆盖 Claude Code 全部生命周期事件，PermissionRequest 使用 24 小时超时。
/// </summary>
public sealed class ClaudeHookConfiguration(string? claudeConfigDir = null)
{
    public const string ManagedStatus = "Managed by AgentPager (Claude Code)";
    private const string LegacyManagedStatus = "Managed by AgentGrid (Claude Code)";

    private static readonly (string Name, string? Matcher, int? Timeout)[] Events =
    [
        ("SessionStart", null, null),
        ("SessionEnd", null, null),
        ("UserPromptSubmit", null, null),
        ("Stop", null, null),
        ("StopFailure", null, null),
        ("SubagentStart", null, null),
        ("SubagentStop", null, null),
        ("Notification", "*", null),
        ("PreToolUse", "*", null),
        ("PermissionRequest", "*", 86_400),
        ("PostToolUse", "*", null),
        ("PostToolUseFailure", "*", null),
        ("PermissionDenied", "*", null),
        ("PreCompact", null, null),
    ];

    private readonly string _settingsPath = Path.Combine(
        claudeConfigDir ?? ClaudeConfigDirectory.Home,
        "settings.json");

    public string SettingsPath => _settingsPath;

    public bool IsInstalled()
    {
        if (!File.Exists(_settingsPath)) return false;
        try
        {
            var root = JsonNode.Parse(File.ReadAllText(_settingsPath)) as JsonObject;
            var hooks = root?["hooks"] as JsonObject;
            return hooks is not null && Events.All(spec =>
                hooks[spec.Name] is JsonArray groups && groups.Any(node => IsManaged(node as JsonObject)));
        }
        catch { return false; }
    }

    /// <summary>Hook 调用命令："<bridgePath>" --hook --source claude。</summary>
    public static string HookCommand(string executablePath) => $"\"{executablePath}\" --hook --source claude";

    public HookConfigurationChange Install(string executablePath) =>
        Mutate(root =>
        {
            var hooks = root["hooks"] as JsonObject ?? new JsonObject();
            root["hooks"] = hooks;
            var command = HookCommand(executablePath);
            foreach (var spec in Events)
            {
                var groups = hooks[spec.Name] as JsonArray ?? [];
                var retained = new JsonArray(groups.Where(node => !IsManaged(node as JsonObject))
                    .Select(node => node?.DeepClone()).ToArray());
                var handler = new JsonObject
                {
                    ["type"] = "command",
                    ["command"] = command,
                    ["statusMessage"] = ManagedStatus,
                };
                if (spec.Timeout is not null) handler["timeout"] = spec.Timeout;
                var group = new JsonObject { ["hooks"] = new JsonArray(handler) };
                if (spec.Matcher is not null) group["matcher"] = spec.Matcher;
                retained.Add(group);
                hooks[spec.Name] = retained;
            }
            return root;
        });

    public HookConfigurationChange Uninstall() =>
        Mutate(root =>
        {
            if (root["hooks"] is not JsonObject hooks) return root;
            foreach (var spec in Events)
            {
                if (hooks[spec.Name] is not JsonArray groups) continue;
                var retained = new JsonArray(groups.Where(node => !IsManaged(node as JsonObject))
                    .Select(node => node?.DeepClone()).ToArray());
                if (retained.Count == 0) hooks.Remove(spec.Name);
                else hooks[spec.Name] = retained;
            }
            if (hooks.Count == 0) root.Remove("hooks");
            return root;
        }, deleteWhenEmpty: true);

    private HookConfigurationChange Mutate(Func<JsonObject, JsonObject> mutation, bool deleteWhenEmpty = false)
    {
        var original = File.Exists(_settingsPath) ? File.ReadAllText(_settingsPath) : null;
        JsonObject root;
        try { root = original is null ? [] : JsonNode.Parse(original)?.AsObject() ?? []; }
        catch (Exception error) { throw new InvalidDataException("Claude settings.json 不是有效的 JSON。", error); }

        var result = mutation(root);
        var output = result.Count == 0 && deleteWhenEmpty
            ? null
            : result.ToJsonString(new JsonSerializerOptions { WriteIndented = true });
        if (Normalize(original) == Normalize(output)) return new(false);

        Directory.CreateDirectory(Path.GetDirectoryName(_settingsPath)!);
        var backup = original is null ? null : Backup(original);
        if (output is null) File.Delete(_settingsPath);
        else File.WriteAllText(_settingsPath, output + Environment.NewLine);
        return new(true, backup);
    }

    private string Backup(string contents)
    {
        var stem = $"{_settingsPath}.agentpager-claude-backup-{DateTimeOffset.UtcNow.ToUnixTimeSeconds()}";
        var path = stem;
        for (var index = 1; File.Exists(path); index++) path = $"{stem}-{index}";
        File.WriteAllText(path, contents);
        return path;
    }

    private static string? Normalize(string? value) => value?.Replace("\r\n", "\n").Trim();

    private static bool IsManaged(JsonObject? group) =>
        group?["hooks"] is JsonArray handlers && handlers.Any(node =>
        {
            var handler = node as JsonObject;
            var status = handler?["statusMessage"]?.GetValue<string>();
            var command = handler?["command"]?.GetValue<string>();
            return status is ManagedStatus or LegacyManagedStatus ||
                   command?.Contains("AgentPagerBridge", StringComparison.OrdinalIgnoreCase) == true;
        });
}

public static class ClaudeConfigDirectory
{
    public static string Home =>
        Environment.GetEnvironmentVariable("CLAUDE_CONFIG_DIR") is { Length: > 0 } configured
            ? configured
            : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".claude");
}
