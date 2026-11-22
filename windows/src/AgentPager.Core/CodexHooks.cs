using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;

namespace AgentPager.Core;

public enum CodexHookEventName
{
    SessionStart,
    PreToolUse,
    PermissionRequest,
    PostToolUse,
    UserPromptSubmit,
    Stop,
    SessionMetadata,
    SessionOffline,
}

public sealed record HookToolInput(
    JsonElement? Cmd,
    JsonElement? Command,
    string? Description)
{
    [JsonIgnore]
    public string? Summary => Display(Cmd) ?? Display(Command) ?? Description;

    private static string? Display(JsonElement? value)
    {
        if (value is null) return null;
        return value.Value.ValueKind switch
        {
            JsonValueKind.String => value.Value.GetString(),
            JsonValueKind.Array => string.Join(' ', value.Value.EnumerateArray()
                .Where(element => element.ValueKind == JsonValueKind.String)
                .Select(element => element.GetString())),
            _ => null,
        };
    }
}

public sealed record CodexHookPayload(
    string Cwd,
    [property: JsonPropertyName("hook_event_name")] CodexHookEventName HookEventName,
    [property: JsonPropertyName("session_id")] string SessionID,
    string? Source,
    [property: JsonPropertyName("turn_id")] string? TurnID,
    [property: JsonPropertyName("transcript_path")] string? TranscriptPath,
    [property: JsonPropertyName("tool_name")] string? ToolName,
    [property: JsonPropertyName("tool_use_id")] string? ToolUseID,
    [property: JsonPropertyName("tool_input")] HookToolInput? ToolInput,
    string? Prompt,
    string? Model,
    [property: JsonPropertyName("conversation_title")] string? ConversationTitle = null,
    [property: JsonPropertyName("previous_session_id")] string? PreviousSessionID = null)
{
    public static bool IsChatGPTWebID(string? id) => id is not null &&
        System.Text.RegularExpressions.Regex.IsMatch(id, @"\Aagentpager-chatgpt-web-[0-9a-f]{64}\z");

    [JsonIgnore]
    public bool IsChatGPTWeb => IsChatGPTWebID(SessionID);

    [JsonIgnore]
    public string ProjectName => Cwd.TrimEnd('/', '\\').Split('/', '\\').LastOrDefault() is { Length: > 0 } value
        ? value
        : "Codex";
}

public enum CodexPermissionDecision { Allow, Deny }

public static class CodexHookOutput
{
    public static byte[] Permission(CodexPermissionDecision decision)
    {
        var value = new
        {
            @continue = true,
            hookSpecificOutput = new
            {
                hookEventName = "PermissionRequest",
                decision = decision == CodexPermissionDecision.Allow ? "allow" : "deny",
            },
        };
        return System.Text.Encoding.UTF8.GetBytes(JsonSerializer.Serialize(value) + "\n");
    }
}

public sealed record HookConfigurationChange(bool Changed, string? BackupPath = null);

public sealed class CodexHookConfiguration(string? codexHome = null)
{
    public const string ManagedStatus = "Managed by AgentPager";
    private readonly string _hooksPath = Path.Combine(codexHome ?? CodexPaths.Home, "hooks.json");
    private static readonly (string Name, string? Matcher, int Timeout)[] Events =
    [
        ("SessionStart", "startup|resume", 45),
        ("UserPromptSubmit", null, 45),
        ("PreToolUse", null, 45),
        ("PostToolUse", null, 45),
        ("PermissionRequest", null, 3600),
        ("Stop", null, 45),
    ];

    public string HooksPath => _hooksPath;

    public bool IsInstalled()
    {
        if (!File.Exists(_hooksPath)) return false;
        try
        {
            var root = JsonNode.Parse(File.ReadAllText(_hooksPath)) as JsonObject;
            var hooks = root?["hooks"] as JsonObject;
            return hooks is not null && Events.All(spec =>
                hooks[spec.Name] is JsonArray groups && groups.Any(node => IsManaged(node as JsonObject)));
        }
        catch { return false; }
    }

    public HookConfigurationChange Install(string executablePath) =>
        Mutate(root =>
        {
            var hooks = root["hooks"] as JsonObject ?? new JsonObject();
            root["hooks"] = hooks;
            foreach (var spec in Events)
            {
                var groups = hooks[spec.Name] as JsonArray ?? [];
                var retained = new JsonArray(groups.Where(node => !IsManaged(node as JsonObject))
                    .Select(node => node?.DeepClone()).ToArray());
                var command = $"\"{executablePath}\" --hook";
                var handler = new JsonObject
                {
                    ["type"] = "command",
                    ["command"] = command,
                    ["commandWindows"] = command,
                    ["timeout"] = spec.Timeout,
                    ["statusMessage"] = ManagedStatus,
                };
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
        var original = File.Exists(_hooksPath) ? File.ReadAllText(_hooksPath) : null;
        JsonObject root;
        try { root = original is null ? [] : JsonNode.Parse(original)?.AsObject() ?? []; }
        catch (Exception error) { throw new InvalidDataException("Codex hooks.json 不是有效的 JSON。", error); }

        var result = mutation(root);
        var output = result.Count == 0 && deleteWhenEmpty
            ? null
            : result.ToJsonString(new JsonSerializerOptions { WriteIndented = true });
        if (Normalize(original) == Normalize(output)) return new(false);

        Directory.CreateDirectory(Path.GetDirectoryName(_hooksPath)!);
        var backup = original is null ? null : Backup(original);
        if (output is null) File.Delete(_hooksPath);
        else File.WriteAllText(_hooksPath, output + Environment.NewLine);
        return new(true, backup);
    }

    private string Backup(string contents)
    {
        var stem = $"{_hooksPath}.agentpager-backup-{DateTimeOffset.UtcNow.ToUnixTimeSeconds()}";
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
            var command = handler?["commandWindows"]?.GetValue<string>() ?? handler?["command"]?.GetValue<string>();
            return status is ManagedStatus or "Managed by AgentGrid" ||
                   command?.Contains("AgentPagerBridge", StringComparison.OrdinalIgnoreCase) == true ||
                   command?.Contains("AgentPagerHooks", StringComparison.OrdinalIgnoreCase) == true ||
                   command?.Contains("AgentGridHooks", StringComparison.OrdinalIgnoreCase) == true;
        });
}

public static class CodexPaths
{
    public static string Home =>
        Environment.GetEnvironmentVariable("CODEX_HOME") is { Length: > 0 } configured
            ? configured
            : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex");
}
