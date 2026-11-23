using System.Text.Json;
using System.Text.Json.Serialization;

namespace AgentPager.Core;

public enum AgentSource { CodexDesktop, CodexCLI, ClaudeCode }
public enum AgentLifecycle { Offline, Idle, Starting, Running, WaitingApproval, WaitingAnswer, Succeeded, Interrupted }
public enum AgentActivity { Thinking, Reading, Searching, Editing, Executing, Testing, Browsing, Delegating }
public enum TaskCapability { Approve, Deny, Answer, Interrupt, Retry }
public enum PendingRequestKind { Approval, Question }
public enum ControlAction { Approve, Deny, Answer, Interrupt, Retry, Mute, MarkRead, Pin }
public enum ControlResult { Accepted, Rejected, Stale, Unsupported }

public sealed record TokenUsage(
    int Input = 0,
    int CachedInput = 0,
    int Output = 0,
    int ReasoningOutput = 0,
    int Total = 0);

public sealed record SubagentSnapshot(
    string Id,
    string Path,
    string DisplayName,
    AgentLifecycle Lifecycle,
    AgentActivity? Activity,
    string? LatestStep,
    TokenUsage? TokenUsage,
    DateTimeOffset StartedAt,
    DateTimeOffset UpdatedAt)
{
    [JsonIgnore]
    public bool IsTerminal => Lifecycle is AgentLifecycle.Succeeded or AgentLifecycle.Interrupted;

    public static string NameFromPath(string path)
    {
        var raw = path.Replace('\\', '/').Split('/', StringSplitOptions.RemoveEmptyEntries)
            .LastOrDefault()?.Replace('_', ' ').Replace('-', ' ').Trim();
        return string.IsNullOrEmpty(raw)
            ? "Codex 子代理"
            : char.ToUpperInvariant(raw[0]) + raw[1..];
    }
}

public sealed record TaskSnapshot(
    string Id,
    AgentSource Source,
    string ProjectName,
    string Title,
    string? UserPrompt,
    string? LatestStep,
    TokenUsage? TokenUsage,
    List<SubagentSnapshot> Subagents,
    AgentLifecycle Lifecycle,
    AgentActivity? Activity,
    DateTimeOffset StartedAt,
    DateTimeOffset UpdatedAt,
    DateTimeOffset? CompletedAt,
    bool IsUnread,
    bool IsPinned,
    bool IsMuted,
    HashSet<TaskCapability> Capabilities,
    // 兼容 Claude Code 协议的其他客户端（如 ZCode、WorkBuddy）的展示名；Source 仍是 ClaudeCode。
    // 旧版手机端忽略该字段；null 表示 Claude Code 本身。
    string? AgentName = null)
{
    [JsonIgnore]
    public bool IsTerminal => Lifecycle is AgentLifecycle.Succeeded or AgentLifecycle.Interrupted;

    [JsonIgnore]
    public int EffectivePriority =>
        (Lifecycle switch
        {
            AgentLifecycle.WaitingApproval => 600,
            AgentLifecycle.WaitingAnswer => 500,
            AgentLifecycle.Succeeded => 300,
            AgentLifecycle.Starting or AgentLifecycle.Running => 200,
            _ => 100,
        }) + (IsUnread && Lifecycle == AgentLifecycle.Succeeded ? 50 : 0) + (IsPinned ? 25 : 0);
}

public sealed record UsageWindow(
    string Key,
    string Label,
    double UsedPercentage,
    double RemainingPercentage,
    int WindowMinutes,
    DateTimeOffset? ResetsAt);

public sealed record DailyUsagePoint(
    string Date,
    long InputTokens = 0,
    long CachedInputTokens = 0,
    long OutputTokens = 0,
    long ReasoningOutputTokens = 0,
    long TotalTokens = 0,
    double? EstimatedCostUSD = null);

public sealed record UsageSnapshot(
    DateTimeOffset? CapturedAt,
    string? PlanType,
    string? LimitID,
    List<UsageWindow> Windows,
    List<DailyUsagePoint> DailyUsage);

public sealed record PendingRequest(
    string TaskID,
    PendingRequestKind Kind,
    string? Summary,
    List<string> Options);

public sealed record StateSnapshotPayload(
    List<TaskSnapshot> Tasks,
    UsageSnapshot? Usage,
    string? FocusedTaskID,
    List<PendingRequest> PendingRequests);

public sealed record PairingPayload(
    int Version,
    string ServiceID,
    string Host,
    ushort Port,
    string Secret);

public sealed record ControlPayload(
    string TaskID,
    ControlAction Action,
    string? Value);

public sealed record SignedControlEnvelope(
    int Version,
    Guid MessageId,
    string Type,
    long SentAt,
    string DeviceId,
    ulong Sequence,
    string Nonce,
    ControlPayload Payload,
    string Signature);

public sealed record ControlAckPayload(Guid RequestID, ControlResult Result, string? Reason);

public sealed record MessageEnvelope<T>(
    int Version,
    Guid MessageId,
    string Type,
    long SentAt,
    T Payload)
{
    public static MessageEnvelope<T> Create(string type, T payload) =>
        new(1, Guid.NewGuid(), type, DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(), payload);
}

public static class WireJson
{
    public static JsonSerializerOptions Options { get; } = Create();

    private static JsonSerializerOptions Create()
    {
        var options = new JsonSerializerOptions
        {
            PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
            PropertyNameCaseInsensitive = true,
            DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
            WriteIndented = false,
        };
        options.Converters.Add(new CodexHookEventNameConverter());
        options.Converters.Add(new WireEnumConverterFactory());
        options.Converters.Add(new UnixMillisecondsConverter());
        options.Converters.Add(new NullableUnixMillisecondsConverter());
        return options;
    }
}

internal sealed class CodexHookEventNameConverter : JsonConverter<CodexHookEventName>
{
    public override CodexHookEventName Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
        Enum.TryParse<CodexHookEventName>(reader.GetString(), ignoreCase: false, out var result)
            ? result
            : throw new JsonException("未知的 Codex Hook 事件。");

    public override void Write(Utf8JsonWriter writer, CodexHookEventName value, JsonSerializerOptions options) =>
        writer.WriteStringValue(value.ToString());
}

internal sealed class UnixMillisecondsConverter : JsonConverter<DateTimeOffset>
{
    public override DateTimeOffset Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
        DateTimeOffset.FromUnixTimeMilliseconds(reader.GetInt64());

    public override void Write(Utf8JsonWriter writer, DateTimeOffset value, JsonSerializerOptions options) =>
        writer.WriteNumberValue(value.ToUnixTimeMilliseconds());
}

internal sealed class NullableUnixMillisecondsConverter : JsonConverter<DateTimeOffset?>
{
    public override DateTimeOffset? Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
        reader.TokenType == JsonTokenType.Null ? null : DateTimeOffset.FromUnixTimeMilliseconds(reader.GetInt64());

    public override void Write(Utf8JsonWriter writer, DateTimeOffset? value, JsonSerializerOptions options)
    {
        if (value is null) writer.WriteNullValue();
        else writer.WriteNumberValue(value.Value.ToUnixTimeMilliseconds());
    }
}

internal sealed class WireEnumConverterFactory : JsonConverterFactory
{
    public override bool CanConvert(Type typeToConvert) => typeToConvert.IsEnum;

    public override JsonConverter CreateConverter(Type typeToConvert, JsonSerializerOptions options) =>
        (JsonConverter)Activator.CreateInstance(typeof(WireEnumConverter<>).MakeGenericType(typeToConvert))!;
}

internal sealed class WireEnumConverter<T> : JsonConverter<T> where T : struct, Enum
{
    public override T Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        var value = reader.GetString() ?? throw new JsonException();
        foreach (var candidate in Enum.GetValues<T>())
            if (WireName(candidate).Equals(value, StringComparison.Ordinal))
                return candidate;
        throw new JsonException($"未知的 {typeof(T).Name} 值：{value}");
    }

    public override void Write(Utf8JsonWriter writer, T value, JsonSerializerOptions options) =>
        writer.WriteStringValue(WireName(value));

    private static string WireName(T value)
    {
        var name = value.ToString();
        if (typeof(T) == typeof(AgentSource))
        {
            if (name == nameof(AgentSource.CodexCLI)) return "codexCLI";
            if (name == nameof(AgentSource.ClaudeCode)) return "claudeCode";
        }
        return char.ToLowerInvariant(name[0]) + name[1..];
    }
}
