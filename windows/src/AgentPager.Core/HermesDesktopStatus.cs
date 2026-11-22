using System.Text.Json;
using System.Security.Cryptography;
using System.Text;

namespace AgentPager.Core;

public sealed record HermesConversation(string Id, string Title, AgentLifecycle Lifecycle, DateTimeOffset UpdatedAt)
{
    public string? AgentName { get; init; }
    public SessionModelUsage? ModelUsage { get; init; }
    public int ActiveSubagents { get; init; }
}

public sealed record HermesHeartbeat(AgentLifecycle Lifecycle, DateTimeOffset UpdatedAt)
{
    public const int MaximumBytes = 32_768;
    public const int MaximumSessions = 20;
    public const int MaximumTitleLength = 160;
    public static readonly TimeSpan Timeout = TimeSpan.FromSeconds(90);
    // null = legacy aggregate heartbeat; empty = authoritative connected-with-no-conversations snapshot.
    public IReadOnlyList<HermesConversation>? Conversations { get; init; }

    public static HermesHeartbeat? Parse(ReadOnlyMemory<byte> json, DateTimeOffset now, string? token = null)
    {
        if (json.Length > MaximumBytes) return null;
        try
        {
            using var document = JsonDocument.Parse(json, new JsonDocumentOptions { MaxDepth = 5 });
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object ||
                !root.TryGetProperty("version", out var version) || !version.TryGetInt32(out var v) || v is not (1 or 2) ||
                v == 1 && json.Length > 1_024 ||
                !root.TryGetProperty("state", out var state) || state.ValueKind != JsonValueKind.String ||
                !Timestamp(root, now, out var updatedAt) ||
                LifecycleOf(state.GetString(), conversation: false) is not { } lifecycle) return null;
            if (token is not null && (now - updatedAt >= Timeout || token.Length != 64 ||
                !root.TryGetProperty("token", out var field) || field.ValueKind != JsonValueKind.String ||
                field.GetString() is not { Length: 64 } supplied ||
                !CryptographicOperations.FixedTimeEquals(Encoding.ASCII.GetBytes(supplied), Encoding.ASCII.GetBytes(token)))) return null;
            if (v == 1) return new(lifecycle, updatedAt);

            if (root.EnumerateObject().Any(field => field.Name is not ("version" or "state" or "updatedAt" or "token" or "sessions")) ||
                !root.TryGetProperty("sessions", out var sessions) || sessions.ValueKind != JsonValueKind.Array ||
                sessions.GetArrayLength() > MaximumSessions) return null;
            var conversations = new List<HermesConversation>();
            var ids = new HashSet<string>(StringComparer.Ordinal);
            foreach (var row in sessions.EnumerateArray())
            {
                if (row.ValueKind != JsonValueKind.Object ||
                    row.EnumerateObject().Any(field => field.Name is not ("id" or "title" or "state" or "updatedAt" or "modelUsage" or "activeSubagents" or "agentName")) ||
                    !row.TryGetProperty("id", out var idField) || idField.ValueKind != JsonValueKind.String ||
                    idField.GetString() is not { Length: 64 } id || id.Any(ch => ch is not (>= 'a' and <= 'f' or >= '0' and <= '9')) ||
                    !ids.Add(id) || !row.TryGetProperty("title", out var titleField) || titleField.ValueKind != JsonValueKind.String ||
                    titleField.GetString() is not { Length: > 0 and <= MaximumTitleLength } title ||
                    string.IsNullOrWhiteSpace(title) || title.Any(char.IsControl) ||
                    !row.TryGetProperty("state", out var rowState) || rowState.ValueKind != JsonValueKind.String ||
                    LifecycleOf(rowState.GetString(), conversation: true) is not { } rowLifecycle ||
                    !Timestamp(row, now, out var rowUpdatedAt) || rowUpdatedAt > updatedAt) return null;
                string? agentName = null;
                if (row.TryGetProperty("agentName", out var agentField))
                {
                    if (agentField.ValueKind != JsonValueKind.String || agentField.GetString() is not { Length: > 0 and <= MaximumTitleLength } name ||
                        string.IsNullOrWhiteSpace(name) || name.Any(char.IsControl)) return null;
                    agentName = name.Trim();
                }
                SessionModelUsage? usage = null;
                if (row.TryGetProperty("modelUsage", out var usageField))
                {
                    usage = ParseUsage(usageField);
                    if (usage is null) return null;
                }
                var activeSubagents = 0;
                if (row.TryGetProperty("activeSubagents", out var children) && (!children.TryGetInt32(out activeSubagents) || activeSubagents is < 0 or > 1024)) return null;
                conversations.Add(new(id, title.Trim(), rowLifecycle, rowUpdatedAt) { AgentName = agentName, ModelUsage = usage, ActiveSubagents = activeSubagents });
            }
            return new(lifecycle, updatedAt) { Conversations = conversations.AsReadOnly() };
        }
        catch (Exception error) when (error is JsonException or InvalidOperationException or ArgumentOutOfRangeException) { return null; }
    }

    private static SessionModelUsage? ParseUsage(JsonElement value)
    {
        if (value.ValueKind != JsonValueKind.Object || value.EnumerateObject().Any(field => field.Name is not
            ("inputTokens" or "outputTokens" or "totalTokens" or "model" or "provider" or "estimatedCostUSD" or "costSource" or "quota"))) return null;
        foreach (var name in new[] { "inputTokens", "outputTokens", "totalTokens" })
            if (!value.TryGetProperty(name, out var count) || !count.TryGetInt32(out var n) || n < 0) return null;
        foreach (var name in new[] { "model", "provider" })
            if (value.TryGetProperty(name, out var field) && (field.ValueKind != JsonValueKind.String ||
                field.GetString() is not { Length: > 0 and <= MaximumTitleLength } text || text.Any(char.IsControl))) return null;
        if (value.TryGetProperty("estimatedCostUSD", out var cost) &&
            (!cost.TryGetDouble(out var amount) || !double.IsFinite(amount) || amount is < 0 or > 1e9)) return null;
        if (value.TryGetProperty("costSource", out var source) &&
            (source.ValueKind != JsonValueKind.String || source.GetString() is not ("sdk_reported" or "current_model_pricing"))) return null;
        if (value.TryGetProperty("estimatedCostUSD", out _) != value.TryGetProperty("costSource", out _)) return null;
        if (value.TryGetProperty("quota", out var quota))
        {
            if (quota.ValueKind != JsonValueKind.Object || quota.EnumerateObject().Any(field => field.Name is not
                ("label" or "usedPercentage" or "resetsAt" or "source")) ||
                !quota.TryGetProperty("label", out var label) || label.ValueKind != JsonValueKind.String ||
                label.GetString() is not { Length: > 0 and <= MaximumTitleLength } title || title.Any(char.IsControl) ||
                !quota.TryGetProperty("usedPercentage", out var used) || !used.TryGetDouble(out var percent) || !double.IsFinite(percent) || percent is < 0 or > 100 ||
                !quota.TryGetProperty("source", out var quotaSource) || quotaSource.ValueKind != JsonValueKind.String ||
                quotaSource.GetString() is not ("session_plan_gauge" or "provider_cache") ||
                quota.TryGetProperty("resetsAt", out var reset) && (!reset.TryGetInt64(out var ms) || ms <= 0 || ms > 253402300799999)) return null;
        }
        return value.Deserialize<SessionModelUsage>(WireJson.Options);
    }

    private static AgentLifecycle? LifecycleOf(string? state, bool conversation) => state switch
    {
        "running" => AgentLifecycle.Running,
        "idle" => AgentLifecycle.Idle,
        "offline" => AgentLifecycle.Offline,
        "waiting" when conversation => AgentLifecycle.WaitingAnswer,
        "succeeded" when conversation => AgentLifecycle.Succeeded,
        "interrupted" when conversation => AgentLifecycle.Interrupted,
        _ => null,
    };

    private static bool Timestamp(JsonElement row, DateTimeOffset now, out DateTimeOffset timestamp)
    {
        timestamp = default;
        if (!row.TryGetProperty("updatedAt", out var at) || at.ValueKind != JsonValueKind.Number ||
            !at.TryGetInt64(out var ms) || ms <= 0 || ms > now.AddSeconds(5).ToUnixTimeMilliseconds()) return false;
        timestamp = DateTimeOffset.FromUnixTimeMilliseconds(ms);
        return true;
    }
}

/// <summary>Retains the most recent file or authenticated local heartbeat.</summary>
public sealed class HermesDesktopStatus(string? path = null)
{
    private readonly string _path = path ?? DefaultPath();
    private HermesHeartbeat? _lastHeartbeat;
    public DateTimeOffset? LastReceivedAt => _lastHeartbeat?.UpdatedAt;
    public string? Transport { get; private set; }

    public void Accept(HermesHeartbeat heartbeat, string transport)
    {
        if (_lastHeartbeat is { } prior)
        {
            if (heartbeat.UpdatedAt < prior.UpdatedAt) return;
            // A leftover v1 file must not resurrect the aggregate placeholder over a live v2 plugin.
            if (prior.Conversations is not null && heartbeat.Conversations is null &&
                heartbeat.UpdatedAt - prior.UpdatedAt < HermesHeartbeat.Timeout) return;
            if (heartbeat.UpdatedAt == prior.UpdatedAt && transport == "状态文件" && Transport == "本机连接") return;
        }
        _lastHeartbeat = heartbeat;
        Transport = transport;
    }

    public AgentLifecycle? Read(DateTimeOffset now)
    {
        // The writer may be replacing the file. Retain the last valid observation until it expires.
        try
        {
            using var stream = new FileStream(_path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            var buffer = new byte[HermesHeartbeat.MaximumBytes + 1];
            var count = stream.ReadAtLeast(buffer, buffer.Length, false);
            if (HermesHeartbeat.Parse(buffer.AsMemory(0, count), now) is { } heartbeat)
                Accept(heartbeat, "状态文件");
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }

        return Lifecycle(now);
    }

    public HermesHeartbeat? Snapshot(DateTimeOffset now)
    {
        if (_lastHeartbeat is not { } heartbeat) return null;
        var lifecycle = now - heartbeat.UpdatedAt >= HermesHeartbeat.Timeout ? AgentLifecycle.Offline : heartbeat.Lifecycle;
        return heartbeat with { Lifecycle = lifecycle, Conversations = heartbeat.Conversations?.Select(row =>
            lifecycle == AgentLifecycle.Offline || now - row.UpdatedAt >= HermesHeartbeat.Timeout
                ? row with { Lifecycle = AgentLifecycle.Offline } : row).ToArray() };
    }

    public AgentLifecycle? Lifecycle(DateTimeOffset now) => Snapshot(now)?.Lifecycle;

    private static string DefaultPath()
    {
        var overrideDirectory = Environment.GetEnvironmentVariable("HERMES_DESKTOP_USER_DATA_DIR");
        var directory = string.IsNullOrEmpty(overrideDirectory)
            ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                "Hermes" + Environment.GetEnvironmentVariable("HERMES_DATA_DIR_SUFFIX"))
            : overrideDirectory;
        return Path.Combine(directory, "plugin-files", "data", "agentpager-status", "status.json");
    }
}
