using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace AgentPager.Core;

/// <summary>安装、卸载第三方客户端 Hook 时的可展示错误。</summary>
public sealed class AgentIntegrationException(string message, Exception? inner = null)
    : Exception(message, inner);

/// <summary>
/// 某个 <see cref="AgentIntegration"/> 在本机上的 Hook 安装入口。
/// 与 <see cref="ClaudeHookConfiguration"/> 同样的安全约束：改写前备份、保留用户既有配置、
/// 无法解析或结构异常的配置一律拒绝改动；并且只在检测到客户端存在时才写，
/// 避免凭空创建目录让别的工具误判该客户端已安装。
/// </summary>
public sealed class AgentIntegrationConfiguration(AgentIntegration integration, string? home = null)
{
    private const string ManagedStatus = "Managed by AgentPager";
    private const int ZcodeDefaultTimeout = 60;

    private static readonly JsonSerializerOptions WriteOptions = new()
    {
        WriteIndented = true,
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    private readonly string _home = home ?? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);

    public AgentIntegration Integration => integration;

    public string ConfigFile => integration.ConfigFile(_home);

    /// <summary>客户端的数据目录是否存在。</summary>
    public bool IsClientDetected() => Directory.Exists(integration.PresenceDirectory(_home));

    public bool IsInstalled()
    {
        var root = TryReadRoot();
        if (root is null) return false;
        return integration.Format switch
        {
            IntegrationConfigFormat.ZcodeConfig =>
                root["hooks"] is JsonObject hooks &&
                hooks["events"] is JsonObject events &&
                integration.Events.All(spec => HasManaged(events[spec.Name])),
            _ =>
                root["hooks"] is JsonObject hooks &&
                integration.Events.All(spec => HasManaged(hooks[spec.Name])),
        };
    }

    /// <summary>ZCode 的 hooks.enabled 总开关被用户关闭：Hook 已写入但不会运行。</summary>
    public bool IsDormant() =>
        integration.Format == IntegrationConfigFormat.ZcodeConfig &&
        IsInstalled() &&
        TryReadRoot()?["hooks"] is JsonObject hooks &&
        hooks["enabled"] is JsonValue enabled &&
        enabled.TryGetValue<bool>(out var value) &&
        !value;

    public HookConfigurationChange Install(string executablePath)
    {
        if (!IsClientDetected())
            throw new AgentIntegrationException(
                $"未检测到 {integration.DisplayName}（~/{integration.PresencePath} 不存在），请先安装并启动一次该客户端");
        var command = integration.HookCommand(executablePath);
        return Mutate(root =>
        {
            if (integration.Format == IntegrationConfigFormat.ZcodeConfig) InstallZcode(root, command);
            else InstallClaudeFamily(root, command);
        }, deleteWhenEmpty: false);
    }

    public HookConfigurationChange Uninstall()
    {
        if (!File.Exists(ConfigFile)) return new(false);
        return Mutate(root =>
        {
            if (integration.Format == IntegrationConfigFormat.ZcodeConfig) UninstallZcode(root);
            else UninstallClaudeFamily(root);
        }, deleteWhenEmpty: true);
    }

    // MARK: - Claude 系

    private void InstallClaudeFamily(JsonObject root, string command)
    {
        var hooks = ObjectAt(root, "hooks", create: true)!;
        foreach (var spec in integration.Events)
        {
            var groups = ArrayAt(hooks, spec.Name);
            var retained = new JsonArray(groups
                .Where(node => !IsManaged(node as JsonObject))
                .Select(node => node?.DeepClone()).ToArray());
            var handler = new JsonObject
            {
                ["type"] = "command",
                ["command"] = command,
                ["statusMessage"] = ManagedStatus,
            };
            if (spec.Timeout is { } timeout) handler["timeout"] = timeout;
            var group = new JsonObject { ["hooks"] = new JsonArray(handler) };
            if (spec.Matcher is not null) group["matcher"] = spec.Matcher;
            retained.Add(group);
            hooks[spec.Name] = retained;
        }
    }

    private void UninstallClaudeFamily(JsonObject root)
    {
        if (root["hooks"] is not JsonObject hooks) return;
        RemoveManagedGroups(hooks);
        if (hooks.Count == 0) root.Remove("hooks");
    }

    // MARK: - ZCode

    private void InstallZcode(JsonObject root, string command)
    {
        var hooks = ObjectAt(root, "hooks", create: true)!;
        var events = ObjectAt(hooks, "events", create: true)!;
        RemoveManagedGroups(events);
        foreach (var spec in integration.Events)
        {
            var groups = ArrayAt(events, spec.Name);
            var retained = new JsonArray(groups.Select(node => node?.DeepClone()).ToArray());
            var handler = new JsonObject { ["type"] = "command", ["command"] = command };
            // 只有超过 ZCode 单个 Hook 默认超时（60 秒）的事件才需要显式写 timeout。
            if (spec.Timeout is { } timeout && timeout > ZcodeDefaultTimeout) handler["timeout"] = timeout;
            retained.Add(new JsonObject { ["hooks"] = new JsonArray(handler) });
            events[spec.Name] = retained;
        }
        // enabled 是用户对其所有 Hook 的总开关：明确设为 false 时绝不改回 true，
        // 否则会悄悄重新启用用户关掉的第三方 Hook。此时我们的 Hook 保持休眠。
        if (hooks["enabled"] is null) hooks["enabled"] = true;
    }

    private void UninstallZcode(JsonObject root)
    {
        if (root["hooks"] is not JsonObject hooks) return;
        if (hooks["events"] is not JsonObject events) return;
        if (!RemoveManagedGroups(events)) return;
        // 只剩我们自己搭的 enabled/events 脚手架时整体移除，不留 {"enabled":true,"events":{}}。
        if (events.Count == 0)
        {
            hooks.Remove("events");
            if (hooks.All(pair => pair.Key == "enabled")) root.Remove("hooks");
        }
    }

    // MARK: - 共用

    /// <summary>移除任何事件下的管理项；空事件键一并删除。返回是否真的移除了东西。</summary>
    private static bool RemoveManagedGroups(JsonObject eventMap)
    {
        var removedAny = false;
        foreach (var name in eventMap.Select(pair => pair.Key).ToList())
        {
            if (eventMap[name] is not JsonArray groups) continue;
            var retained = groups.Where(node => !IsManaged(node as JsonObject)).ToList();
            if (retained.Count == groups.Count) continue;
            removedAny = true;
            if (retained.Count == 0) eventMap.Remove(name);
            else eventMap[name] = new JsonArray(retained.Select(node => node?.DeepClone()).ToArray());
        }
        return removedAny;
    }

    private static bool HasManaged(JsonNode? groups) =>
        groups is JsonArray array && array.Any(node => IsManaged(node as JsonObject));

    private static bool IsManaged(JsonObject? group) =>
        group?["hooks"] is JsonArray handlers && handlers.Any(node =>
        {
            var handler = node as JsonObject;
            var status = handler?["statusMessage"] is JsonValue s && s.TryGetValue<string>(out var text) ? text : null;
            var command = handler?["command"] is JsonValue c && c.TryGetValue<string>(out var line) ? line : null;
            return status == ManagedStatus ||
                   command?.Contains("AgentPagerBridge", StringComparison.OrdinalIgnoreCase) == true;
        });

    /// <summary>取对象子节点；不存在时可创建，类型不符一律视为配置损坏。</summary>
    private JsonObject? ObjectAt(JsonObject parent, string key, bool create)
    {
        switch (parent[key])
        {
            case JsonObject existing:
                return existing;
            case null when create:
                var created = new JsonObject();
                parent[key] = created;
                return created;
            case null:
                return null;
            default:
                throw Corrupt($"“{key}”不是对象");
        }
    }

    private JsonArray ArrayAt(JsonObject parent, string key) => parent[key] switch
    {
        null => new JsonArray(),
        JsonArray array => array,
        _ => throw Corrupt($"“{key}”不是数组"),
    };

    private AgentIntegrationException Corrupt(string detail) =>
        new($"{integration.DisplayName} 的配置 {integration.DisplayConfigPath} 结构异常（{detail}），为避免破坏你的配置，已拒绝修改");

    private JsonObject? TryReadRoot()
    {
        try
        {
            return File.Exists(ConfigFile) ? JsonNode.Parse(File.ReadAllText(ConfigFile)) as JsonObject : null;
        }
        catch (Exception error) when (error is JsonException or IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    private HookConfigurationChange Mutate(Action<JsonObject> mutation, bool deleteWhenEmpty)
    {
        string? original;
        try { original = File.Exists(ConfigFile) ? File.ReadAllText(ConfigFile) : null; }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            throw new AgentIntegrationException($"无法读取配置文件 {integration.DisplayConfigPath}", error);
        }

        JsonObject root;
        try
        {
            root = original is null || string.IsNullOrWhiteSpace(original)
                ? new JsonObject()
                : JsonNode.Parse(original) as JsonObject ?? throw Corrupt("顶层不是对象");
        }
        catch (JsonException error)
        {
            throw new AgentIntegrationException(
                $"{integration.DisplayConfigPath} 不是标准 JSON（可能含注释或已损坏），为避免破坏你的配置，已拒绝修改", error);
        }

        mutation(root);
        var output = root.Count == 0 && deleteWhenEmpty ? null : root.ToJsonString(WriteOptions);
        if (Normalize(original) == Normalize(output)) return new(false);

        Directory.CreateDirectory(Path.GetDirectoryName(ConfigFile)!);
        var backup = original is null ? null : Backup(original);
        if (output is null) File.Delete(ConfigFile);
        else File.WriteAllText(ConfigFile, output + Environment.NewLine);
        return new(true, backup);
    }

    private string Backup(string contents)
    {
        var stem = $"{ConfigFile}.agentpager-{integration.Id}-backup-{DateTimeOffset.UtcNow.ToUnixTimeSeconds()}";
        var path = stem;
        for (var index = 1; File.Exists(path); index++) path = $"{stem}-{index}";
        File.WriteAllText(path, contents);
        return path;
    }

    private static string? Normalize(string? value) => value?.Replace("\r\n", "\n").Trim();
}
