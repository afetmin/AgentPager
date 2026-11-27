using System.Text;
using System.Text.Json;

namespace AgentPager.Core;

public sealed class CodexRolloutObserver
{
    private sealed class TrackedFile(
        string path,
        string sessionID,
        string cwd,
        long offset,
        string? subagentID = null,
        string? subagentPath = null,
        DateTimeOffset? minimumEventTime = null)
    {
        public string Path { get; } = path;
        public string SessionID { get; } = sessionID;
        public string Cwd { get; } = cwd;
        public string? SubagentID { get; } = subagentID;
        public string? SubagentPath { get; } = subagentPath;
        public DateTimeOffset? MinimumEventTime { get; } = minimumEventTime;
        public long Offset { get; set; } = offset;
        public byte[] Pending { get; set; } = [];
    }

    private readonly Dictionary<string, TrackedFile> _tracked = new(StringComparer.OrdinalIgnoreCase);
    private Dictionary<string, long>? _coldFileLengths;
    private readonly string _sessionsRoot;
    private DateTimeOffset _nextDiscovery = DateTimeOffset.MinValue;

    public CodexRolloutObserver(string? sessionsRoot = null) =>
        _sessionsRoot = sessionsRoot ?? Path.Combine(CodexPaths.Home, "sessions");

    public void Include(CodexHookPayload hook)
    {
        if (!string.IsNullOrWhiteSpace(hook.TranscriptPath))
            Track(hook.TranscriptPath, hook.SessionID, hook.Cwd, readExisting: false);
    }

    public List<CodexRolloutSignal> Observe(DateTimeOffset? now = null)
    {
        var current = now ?? DateTimeOffset.UtcNow;
        if (current >= _nextDiscovery)
        {
            Discover(current - TimeSpan.FromMinutes(10));
            _nextDiscovery = current + TimeSpan.FromSeconds(3);
        }

        var signals = new List<CodexRolloutSignal>();
        foreach (var tracked in _tracked.Values.ToList())
        {
            try
            {
                var info = new FileInfo(tracked.Path);
                if (!info.Exists) continue;
                if (info.Length < tracked.Offset)
                {
                    tracked.Offset = info.Length;
                    tracked.Pending = [];
                    continue;
                }
                if (info.Length == tracked.Offset) continue;
                using var stream = new FileStream(tracked.Path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
                stream.Seek(tracked.Offset, SeekOrigin.Begin);
                using var memory = new MemoryStream();
                stream.CopyTo(memory);
                tracked.Offset = info.Length;
                var appended = memory.ToArray();
                var data = new byte[tracked.Pending.Length + appended.Length];
                tracked.Pending.CopyTo(data, 0);
                appended.CopyTo(data, tracked.Pending.Length);
                var start = 0;
                for (var index = 0; index < data.Length; index++)
                {
                    if (data[index] != (byte)'\n') continue;
                    if (index > start)
                    {
                        var line = Encoding.UTF8.GetString(data, start, index - start);
                        var signal = ParseLine(line, tracked.SessionID, tracked.Cwd,
                            tracked.SubagentID, tracked.SubagentPath, current, tracked.MinimumEventTime);
                        if (signal is not null)
                        {
                            signals.Add(signal);
                            if (tracked.SubagentID is null &&
                                signal.SubagentID is not null &&
                                signal.SubagentPath is not null)
                                TrackSubagent(signal, Path.GetDirectoryName(tracked.Path)!);
                        }
                    }
                    start = index + 1;
                }
                tracked.Pending = data[start..];
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
        return signals.OrderBy(value => value.Timestamp).ToList();
    }

    private void Discover(DateTimeOffset modifiedAfter)
    {
        if (!Directory.Exists(_sessionsRoot)) return;
        var coldFiles = new Dictionary<string, long>(StringComparer.OrdinalIgnoreCase);
        try
        {
            foreach (var info in new DirectoryInfo(_sessionsRoot).EnumerateFiles("*.jsonl", SearchOption.AllDirectories))
            {
                var path = info.FullName;
                if (_tracked.ContainsKey(path)) continue;
                var oldWriteTime = info.LastWriteTimeUtc < modifiedAfter.UtcDateTime;
                if (oldWriteTime)
                {
                    // Codex can append on Windows while the open writer still exposes the old mtime.
                    // Baseline untouched logs, and also notice a restored JSONL that reappears with an old mtime.
                    var length = info.Length;
                    if (_coldFileLengths is null ||
                        _coldFileLengths.TryGetValue(path, out var previous) && previous == length)
                    {
                        coldFiles[path] = length;
                        continue;
                    }
                }
                var metadata = ReadMetadata(path);
                if (metadata is null) continue;
                Track(path, metadata.Value.SessionID, metadata.Value.Cwd, readExisting: true,
                    maximumReplayBytes: 2 * 1024 * 1024, minimumEventTime: oldWriteTime ? modifiedAfter : null);
            }
            _coldFileLengths = coldFiles;
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    private void Track(
        string path,
        string sessionID,
        string cwd,
        bool readExisting,
        long? maximumReplayBytes = null,
        string? subagentID = null,
        string? subagentPath = null,
        DateTimeOffset? minimumEventTime = null)
    {
        var fullPath = Path.GetFullPath(path);
        if (_tracked.ContainsKey(fullPath)) return;
        var size = File.Exists(fullPath) ? new FileInfo(fullPath).Length : 0;
        var offset = readExisting
            ? maximumReplayBytes is not null ? Math.Max(0, size - maximumReplayBytes.Value) : 0
            : size;
        _tracked[fullPath] = new(fullPath, sessionID, cwd, offset, subagentID, subagentPath, minimumEventTime);
    }

    private void TrackSubagent(CodexRolloutSignal signal, string nearbyDirectory)
    {
        var id = signal.SubagentID!;
        if (_tracked.Values.Any(value => value.SubagentID == id)) return;
        string? path = null;
        try
        {
            path = Directory.EnumerateFiles(nearbyDirectory, $"*{id}*.jsonl", SearchOption.TopDirectoryOnly).FirstOrDefault();
            path ??= Directory.Exists(_sessionsRoot)
                ? Directory.EnumerateFiles(_sessionsRoot, $"*{id}*.jsonl", SearchOption.AllDirectories).FirstOrDefault()
                : null;
        }
        catch (IOException) { }
        if (path is not null)
            Track(path, signal.SessionID, signal.Cwd, readExisting: true, subagentID: id, subagentPath: signal.SubagentPath);
    }

    private static (string SessionID, string Cwd)? ReadMetadata(string path)
    {
        try
        {
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            using var reader = new StreamReader(stream);
            var line = reader.ReadLine();
            if (line is null) return null;
            using var document = JsonDocument.Parse(line);
            var root = document.RootElement;
            if (root.GetStringOrNull("type") != "session_meta" ||
                !root.TryGetProperty("payload", out var payload))
                return null;
            if (payload.TryGetProperty("source", out var source) &&
                source.ValueKind == JsonValueKind.Object &&
                source.TryGetProperty("subagent", out _))
                return null;
            var id = payload.GetStringOrNull("id") ?? payload.GetStringOrNull("session_id");
            var cwd = payload.GetStringOrNull("cwd");
            return string.IsNullOrWhiteSpace(id) || string.IsNullOrWhiteSpace(cwd) ? null : (id, cwd);
        }
        catch (Exception error) when (error is IOException or JsonException or UnauthorizedAccessException) { return null; }
    }

    public static CodexRolloutSignal? ParseLine(
        string line,
        string sessionID,
        string cwd,
        string? trackedSubagentID = null,
        string? trackedSubagentPath = null,
        DateTimeOffset? now = null,
        DateTimeOffset? minimumEventTime = null)
    {
        try
        {
            using var document = JsonDocument.Parse(line);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object) return null;
            var rootType = root.GetStringOrNull("type");
            if (!root.TryGetProperty("payload", out var payload) ||
                payload.ValueKind != JsonValueKind.Object)
                return null;
            var type = payload.GetStringOrNull("type");
            if (type is null) return null;
            var recordedAt = ParseTimestamp(root.GetStringOrNull("timestamp"));
            // Length changes discover a file, but only fresh dated events prove fresh work.
            if (minimumEventTime is { } cutoff && (recordedAt is null || recordedAt.Value < cutoff)) return null;
            var timestamp = recordedAt ?? now ?? DateTimeOffset.UtcNow;

            CodexRolloutSignal Signal(
                AgentLifecycle? lifecycle,
                AgentActivity? activity,
                PendingRequestKind? requestKind = null,
                string? summary = null,
                string? userPrompt = null,
                string? latestStep = null,
                TokenUsage? usage = null,
                string? childID = null,
                string? childPath = null,
                DateTimeOffset? occurredAt = null) =>
                new(sessionID, cwd, lifecycle, activity, requestKind, summary, userPrompt,
                    latestStep, usage, childID ?? trackedSubagentID, childPath ?? trackedSubagentPath,
                    occurredAt ?? timestamp);

            if (rootType == "response_item" &&
                type is "function_call" or "custom_tool_call" or "tool_search_call")
            {
                var name = payload.GetStringOrNull("name") ?? (type == "tool_search_call" ? "tool_search" : null);
                var arguments = payload.GetStringOrNull("arguments") ?? payload.GetStringOrNull("input");
                return Signal(AgentLifecycle.Running, CodexEventReducer.ActivityFor(name),
                    latestStep: CodexEventReducer.LatestStep(name, ArgumentSummary(arguments)));
            }
            if (rootType != "event_msg") return null;

            return type switch
            {
                "task_started" or "turn_started" => Signal(AgentLifecycle.Running, AgentActivity.Thinking),
                "task_complete" or "turn_complete" => Signal(AgentLifecycle.Succeeded, null),
                "turn_aborted" => Signal(AgentLifecycle.Interrupted, null),
                "agent_reasoning" or "agent_reasoning_raw_content" or "agent_reasoning_section_break" or "context_compacted"
                    => Signal(AgentLifecycle.Running, AgentActivity.Thinking),
                "user_message" => Signal(AgentLifecycle.Running, AgentActivity.Thinking,
                    userPrompt: Clip(payload.GetStringOrNull("message"), 240)),
                "token_count" => ParseUsage(payload) is { } usage
                    ? Signal(null, null, usage: usage) : null,
                "sub_agent_activity" => trackedSubagentID is null &&
                                        payload.GetStringOrNull("agent_thread_id") is { } childID &&
                                        payload.GetStringOrNull("agent_path") is { } childPath
                    ? Signal(AgentLifecycle.Running, AgentActivity.Thinking,
                        childID: childID, childPath: childPath,
                        occurredAt: Milliseconds(payload, "occurred_at_ms") ?? timestamp)
                    : null,
                "exec_command_begin" or "terminal_interaction" =>
                    Signal(AgentLifecycle.Running, AgentActivity.Executing,
                        latestStep: Clip(Display(payload, "command") ?? Display(payload, "cmd"))),
                "patch_apply_begin" or "patch_apply_updated" =>
                    Signal(AgentLifecycle.Running, AgentActivity.Editing, latestStep: "apply_patch"),
                "mcp_tool_call_begin" or "dynamic_tool_call_request" =>
                    Signal(AgentLifecycle.Running, AgentActivity.Executing,
                        latestStep: CodexEventReducer.LatestStep(
                            payload.GetStringOrNull("tool_name") ?? payload.GetStringOrNull("name"),
                            Clip(payload.GetStringOrNull("reason") ?? payload.GetStringOrNull("message")))),
                "web_search_begin" or "web_search_end" =>
                    Signal(AgentLifecycle.Running, AgentActivity.Browsing,
                        latestStep: Prefix("Web", Clip(payload.GetStringOrNull("query")))),
                "image_generation_begin" or "image_generation_end" or "view_image_tool_call" =>
                    Signal(AgentLifecycle.Running, AgentActivity.Reading, latestStep: "Image"),
                "plan_update" => Signal(AgentLifecycle.Running, AgentActivity.Thinking, latestStep: "更新计划"),
                "exec_command_end" or "patch_apply_end" or "mcp_tool_call_end" or "dynamic_tool_call_response" =>
                    Signal(AgentLifecycle.Running, AgentActivity.Thinking),
                "request_user_input" or "elicitation_request" =>
                    Signal(AgentLifecycle.WaitingAnswer, AgentActivity.Thinking, PendingRequestKind.Question,
                        Clip(payload.GetStringOrNull("prompt") ?? payload.GetStringOrNull("message"))),
                "exec_approval_request" or "apply_patch_approval_request" or "request_permissions" =>
                    Signal(AgentLifecycle.WaitingApproval, AgentActivity.Executing, PendingRequestKind.Approval,
                        Clip(payload.GetStringOrNull("reason") ?? payload.GetStringOrNull("message"))),
                _ => null,
            };
        }
        catch (JsonException) { return null; }
    }

    private static TokenUsage? ParseUsage(JsonElement payload)
    {
        if (!payload.TryGetProperty("info", out var info) ||
            !info.TryGetProperty("total_token_usage", out var total))
            return null;
        return new(
            total.GetIntOrZero("input_tokens"),
            total.GetIntOrZero("cached_input_tokens"),
            total.GetIntOrZero("output_tokens"),
            total.GetIntOrZero("reasoning_output_tokens"),
            total.GetIntOrZero("total_tokens"));
    }

    private static string? ArgumentSummary(string? raw)
    {
        if (string.IsNullOrWhiteSpace(raw)) return null;
        try
        {
            using var document = JsonDocument.Parse(raw);
            if (document.RootElement.ValueKind == JsonValueKind.Object)
                foreach (var key in new[] { "cmd", "command", "query", "path", "ref_id", "step" })
                    if (Display(document.RootElement, key) is { } value)
                        return Clip(value);
        }
        catch (JsonException) { }
        return Clip(raw);
    }

    private static string? Display(JsonElement payload, string key)
    {
        if (!payload.TryGetProperty(key, out var value)) return null;
        return value.ValueKind switch
        {
            JsonValueKind.String => value.GetString(),
            JsonValueKind.Array => string.Join(' ', value.EnumerateArray()
                .Where(item => item.ValueKind == JsonValueKind.String)
                .Select(item => item.GetString())),
            JsonValueKind.Number => value.GetRawText(),
            _ => null,
        };
    }

    private static DateTimeOffset? ParseTimestamp(string? value) =>
        DateTimeOffset.TryParse(value, out var result) ? result : null;

    private static DateTimeOffset? Milliseconds(JsonElement payload, string key) =>
        payload.TryGetProperty(key, out var value) && value.TryGetInt64(out var milliseconds)
            ? DateTimeOffset.FromUnixTimeMilliseconds(milliseconds) : null;

    private static string? Prefix(string prefix, string? detail) => detail is null ? prefix : $"{prefix} {detail}";

    private static string? Clip(string? value, int limit = 220)
    {
        if (value is null) return null;
        var normalized = value.Replace('\n', ' ').Trim();
        return normalized.Length == 0 ? null : normalized[..Math.Min(limit, normalized.Length)];
    }
}

internal static class JsonElementExtensions
{
    public static string? GetStringOrNull(this JsonElement element, string name) =>
        element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String
            ? value.GetString() : null;

    public static int GetIntOrZero(this JsonElement element, string name) =>
        element.TryGetProperty(name, out var value) && value.TryGetInt32(out var result) ? result : 0;
}
