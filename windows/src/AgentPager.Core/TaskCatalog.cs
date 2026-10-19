using System.Text.Json;

namespace AgentPager.Core;

public sealed record CodexRolloutSignal(
    string SessionID,
    string Cwd,
    AgentLifecycle? Lifecycle,
    AgentActivity? Activity,
    PendingRequestKind? RequestKind,
    string? Summary,
    string? UserPrompt,
    string? LatestStep,
    TokenUsage? TokenUsage,
    string? SubagentID,
    string? SubagentPath,
    DateTimeOffset Timestamp);

public sealed record TaskCatalogProjection(
    ulong Revision,
    List<TaskSnapshot> Tasks,
    string? FocusedTaskID,
    List<PendingRequest> PendingRequests);

public interface ICodexPermissionResolver
{
    bool Resolve(string sessionID, CodexPermissionDecision decision);
}

public sealed class TaskCatalog
{
    private readonly List<TaskSnapshot> _tasks;
    private readonly Dictionary<string, PendingRequest> _requests;
    private readonly int _capacity;
    private ulong _revision;

    public TaskCatalog(IEnumerable<TaskSnapshot>? restoring = null, int capacity = 20)
    {
        _tasks = restoring?.ToList() ?? [];
        _requests = [];
        _capacity = capacity;
        Normalize(DateTimeOffset.UtcNow);
    }

    public TaskCatalogProjection Projection(string? focusedTaskIDOverride = null)
    {
        var tasks = _tasks.OrderByDescending(task => task.UpdatedAt).ToList();
        return new(
            _revision,
            tasks,
            focusedTaskIDOverride ?? tasks.MaxBy(task => (task.EffectivePriority, task.UpdatedAt))?.Id,
            _requests.Values.OrderBy(request => request.TaskID).ToList());
    }

    public bool Accept(CodexHookPayload hook, DateTimeOffset? receivedAt = null)
    {
        var now = receivedAt ?? DateTimeOffset.UtcNow;
        var existing = _tasks.FirstOrDefault(task => task.Id == hook.SessionID);
        Upsert(CodexEventReducer.Reduce(hook, existing, now));
        switch (hook.HookEventName)
        {
            case CodexHookEventName.PermissionRequest:
                _requests[hook.SessionID] = new(hook.SessionID, PendingRequestKind.Approval, hook.ToolInput?.Summary, []);
                break;
            case CodexHookEventName.Stop:
                _requests.Remove(hook.SessionID);
                break;
            default:
                if (_tasks.First(task => task.Id == hook.SessionID).Lifecycle == AgentLifecycle.Running)
                    _requests.Remove(hook.SessionID);
                break;
        }
        Changed();
        return true;
    }

    public bool Accept(ClaudeHookPayload hook, DateTimeOffset? receivedAt = null)
    {
        var now = receivedAt ?? DateTimeOffset.UtcNow;
        var existing = _tasks.FirstOrDefault(task => task.Id == hook.SessionID);
        Upsert(ClaudeEventReducer.Reduce(hook, existing, now));
        switch (hook.HookEventName)
        {
            case "PermissionRequest":
                _requests[hook.SessionID] = new(
                    hook.SessionID,
                    PendingRequestKind.Approval,
                    ClaudeEventReducer.Summary(hook.ToolInput) ?? hook.ToolName,
                    []);
                break;
            case "Notification":
                if (ClaudeEventReducer.IsAnswerNotification(hook.NotificationType))
                    _requests[hook.SessionID] = new(
                        hook.SessionID,
                        PendingRequestKind.Question,
                        hook.Title ?? hook.Message,
                        []);
                break;
            case "Stop":
            case "SessionEnd":
            case "PermissionDenied":
                _requests.Remove(hook.SessionID);
                break;
            default:
                if (_tasks.First(task => task.Id == hook.SessionID).Lifecycle == AgentLifecycle.Running)
                    _requests.Remove(hook.SessionID);
                break;
        }
        Changed();
        return true;
    }

    public bool Accept(IEnumerable<CodexRolloutSignal> values)
    {
        var changed = false;
        foreach (var signal in values.OrderBy(value => value.Timestamp))
        {
            Apply(signal);
            changed = true;
        }
        if (changed) Changed();
        return changed;
    }

    public bool Maintain(DateTimeOffset? now = null)
    {
        var before = _tasks.Count + _tasks.Sum(task => task.Subagents.Count);
        Normalize(now ?? DateTimeOffset.UtcNow);
        if (before == _tasks.Count + _tasks.Sum(task => task.Subagents.Count)) return false;
        Changed();
        return true;
    }

    public ControlAckPayload Perform(Guid requestID, ControlPayload control, ICodexPermissionResolver resolver)
    {
        var task = _tasks.FirstOrDefault(candidate => candidate.Id == control.TaskID);
        if (task is null) return new(requestID, ControlResult.Stale, "任务已结束或不存在");

        switch (control.Action)
        {
            case ControlAction.Approve:
            case ControlAction.Deny:
                {
                    var capability = control.Action == ControlAction.Approve ? TaskCapability.Approve : TaskCapability.Deny;
                    if (!task.Capabilities.Contains(capability) ||
                        !_requests.TryGetValue(task.Id, out var request) ||
                        request.Kind != PendingRequestKind.Approval)
                        return new(requestID, ControlResult.Unsupported, "当前任务不能处理该审批");
                    var decision = control.Action == ControlAction.Approve
                        ? CodexPermissionDecision.Allow
                        : CodexPermissionDecision.Deny;
                    if (!resolver.Resolve(task.Id, decision))
                        return new(requestID, ControlResult.Rejected, "Hook 审批通道已失效");
                    _requests.Remove(task.Id);
                    var now = DateTimeOffset.UtcNow;
                    Upsert(task with
                    {
                        Lifecycle = decision == CodexPermissionDecision.Allow
                            ? AgentLifecycle.Running
                            : AgentLifecycle.Interrupted,
                        Activity = decision == CodexPermissionDecision.Allow ? AgentActivity.Thinking : null,
                        UpdatedAt = now,
                        CompletedAt = decision == CodexPermissionDecision.Allow ? null : now,
                        IsUnread = decision == CodexPermissionDecision.Deny || task.IsUnread,
                        Capabilities = [],
                    });
                    Changed();
                    return new(requestID, ControlResult.Accepted, null);
                }
            case ControlAction.Mute:
                Upsert(task with { IsMuted = !task.IsMuted, UpdatedAt = DateTimeOffset.UtcNow });
                break;
            case ControlAction.MarkRead:
                Upsert(task with { IsUnread = false, UpdatedAt = DateTimeOffset.UtcNow });
                break;
            case ControlAction.Pin:
                Upsert(task with { IsPinned = !task.IsPinned, UpdatedAt = DateTimeOffset.UtcNow });
                break;
            default:
                return new(requestID, ControlResult.Unsupported, "当前 Codex 通道暂未提供稳定能力");
        }
        Changed();
        return new(requestID, ControlResult.Accepted, null);
    }

    public bool ApplyTitles(IReadOnlyDictionary<string, string> titles)
    {
        var changed = false;
        for (var index = 0; index < _tasks.Count; index++)
        {
            var task = _tasks[index];
            if (!titles.TryGetValue(task.Id, out var codexTitle)) continue;
            var prefix = $"{task.ProjectName} · ";
            var title = codexTitle == task.ProjectName || codexTitle.StartsWith(prefix, StringComparison.Ordinal)
                ? codexTitle
                : prefix + codexTitle;
            if (title == task.Title) continue;
            _tasks[index] = task with { Title = title };
            changed = true;
        }
        if (changed) Changed();
        return changed;
    }

    private void Apply(CodexRolloutSignal signal)
    {
        var task = _tasks.FirstOrDefault(value => value.Id == signal.SessionID) ??
            NewTask(signal.SessionID, signal.Cwd, signal.Lifecycle ?? AgentLifecycle.Running, signal.Timestamp);

        if (signal.SubagentID is not null)
        {
            ApplySubagent(task, signal);
            return;
        }

        var current = signal.Timestamp >= task.UpdatedAt;
        var lifecycle = signal.Lifecycle is not null && (current || task.Lifecycle == AgentLifecycle.Starting)
            ? signal.Lifecycle.Value : task.Lifecycle;
        var activity = signal.Activity is not null && (current || task.Activity is null)
            ? signal.Activity : task.Activity;
        var prompt = signal.UserPrompt is not null && (current || task.UserPrompt is null)
            ? signal.UserPrompt : task.UserPrompt;
        var title = task.Title;
        if (prompt is not null && title == task.ProjectName)
            title = CodexEventReducer.Title(task.ProjectName, prompt);
        var latestStep = signal.LatestStep is not null && (current || task.LatestStep is null)
            ? signal.LatestStep : task.LatestStep;
        var usage = signal.TokenUsage is not null &&
                    signal.TokenUsage.Total >= (task.TokenUsage?.Total ?? 0)
            ? signal.TokenUsage : task.TokenUsage;
        var updatedAt = signal.Timestamp > task.UpdatedAt ? signal.Timestamp : task.UpdatedAt;
        var terminal = lifecycle is AgentLifecycle.Succeeded or AgentLifecycle.Interrupted;

        task = task with
        {
            Lifecycle = lifecycle,
            Activity = activity,
            UserPrompt = prompt,
            Title = title,
            LatestStep = latestStep,
            TokenUsage = usage,
            UpdatedAt = updatedAt,
            CompletedAt = terminal ? Max(task.CompletedAt, signal.Timestamp) : current ? null : task.CompletedAt,
            IsUnread = terminal || task.IsUnread,
        };
        if (current) task = ApplyRequest(task, signal);
        Upsert(task);
    }

    private TaskSnapshot ApplyRequest(TaskSnapshot task, CodexRolloutSignal signal)
    {
        if (signal.RequestKind == PendingRequestKind.Approval)
        {
            _requests[task.Id] = new(task.Id, PendingRequestKind.Approval, signal.Summary, []);
            return task with
            {
                Capabilities = task.Capabilities.Where(value =>
                    value is TaskCapability.Approve or TaskCapability.Deny).ToHashSet(),
            };
        }
        if (signal.RequestKind == PendingRequestKind.Question)
        {
            _requests[task.Id] = new(task.Id, PendingRequestKind.Question, signal.Summary, []);
            return task with { Capabilities = [] };
        }
        if (signal.Lifecycle == AgentLifecycle.Running || task.IsTerminal)
        {
            _requests.Remove(task.Id);
            return task with { Capabilities = [] };
        }
        return task;
    }

    private void ApplySubagent(TaskSnapshot task, CodexRolloutSignal signal)
    {
        var id = signal.SubagentID!;
        var path = signal.SubagentPath ??
                   task.Subagents.FirstOrDefault(value => value.Id == id)?.Path ??
                   "subagent";
        var subagent = task.Subagents.FirstOrDefault(value => value.Id == id) ??
            new(id, path, SubagentSnapshot.NameFromPath(path),
                signal.Lifecycle ?? AgentLifecycle.Running,
                signal.Activity ?? AgentActivity.Thinking,
                null, null, signal.Timestamp, signal.Timestamp);
        var current = signal.Timestamp >= subagent.UpdatedAt;
        subagent = subagent with
        {
            Path = path,
            DisplayName = SubagentSnapshot.NameFromPath(path),
            Lifecycle = signal.Lifecycle is not null && current ? signal.Lifecycle.Value : subagent.Lifecycle,
            Activity = signal.Activity is not null && (current || subagent.Activity is null)
                ? signal.Activity : subagent.Activity,
            LatestStep = signal.LatestStep is not null && (current || subagent.LatestStep is null)
                ? signal.LatestStep : subagent.LatestStep,
            TokenUsage = signal.TokenUsage is not null &&
                         signal.TokenUsage.Total >= (subagent.TokenUsage?.Total ?? 0)
                ? signal.TokenUsage : subagent.TokenUsage,
            UpdatedAt = signal.Timestamp > subagent.UpdatedAt ? signal.Timestamp : subagent.UpdatedAt,
        };
        var subagents = task.Subagents.Where(value => value.Id != id).Append(subagent)
            .OrderBy(value => value.IsTerminal).ThenBy(value => value.StartedAt).ToList();
        Upsert(task with
        {
            Subagents = subagents,
            UpdatedAt = signal.Timestamp > task.UpdatedAt ? signal.Timestamp : task.UpdatedAt,
            Activity = task.Lifecycle == AgentLifecycle.Running
                ? subagents.Any(value => !value.IsTerminal) ? AgentActivity.Delegating : AgentActivity.Thinking
                : task.Activity,
        });
    }

    private void Normalize(DateTimeOffset now)
    {
        _tasks.RemoveAll(task =>
            task.Id.StartsWith("agentgrid-", StringComparison.Ordinal) && now - task.UpdatedAt >= TimeSpan.FromMinutes(1) ||
            task.IsTerminal && task.CompletedAt is not null && now - task.CompletedAt > TimeSpan.FromHours(1));
        for (var index = 0; index < _tasks.Count; index++)
            _tasks[index] = _tasks[index] with
            {
                Subagents = _tasks[index].Subagents
                    .Where(value => !value.IsTerminal || now - value.UpdatedAt < TimeSpan.FromSeconds(4)).ToList(),
            };
        foreach (var key in _requests.Keys.Where(key => _tasks.All(task => task.Id != key)).ToList())
            _requests.Remove(key);
        while (_tasks.Count > _capacity)
        {
            var removable = _tasks.Where(task => task.IsTerminal).MinBy(task => task.UpdatedAt);
            if (removable is null) break;
            _tasks.Remove(removable);
        }
    }

    private void Changed()
    {
        _revision++;
        Normalize(_tasks.Select(task => task.UpdatedAt).DefaultIfEmpty(DateTimeOffset.UtcNow).Max());
    }

    private void Upsert(TaskSnapshot task)
    {
        var index = _tasks.FindIndex(value => value.Id == task.Id);
        if (index < 0) _tasks.Add(task);
        else _tasks[index] = task;
    }

    private static TaskSnapshot NewTask(string id, string cwd, AgentLifecycle lifecycle, DateTimeOffset now)
    {
        var project = Path.GetFileName(cwd.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar));
        if (string.IsNullOrEmpty(project)) project = "Codex";
        return new(id, AgentSource.CodexCLI, project, project, null, null, null, [],
            lifecycle, null, now, now, null, false, false, false, []);
    }

    private static DateTimeOffset Max(DateTimeOffset? left, DateTimeOffset right) =>
        left is not null && left > right ? left.Value : right;
}

public static class CodexEventReducer
{
    public static TaskSnapshot Reduce(CodexHookPayload hook, TaskSnapshot? existing, DateTimeOffset now)
    {
        var task = existing ?? new(
            hook.SessionID,
            hook.Source == "app" ? AgentSource.CodexDesktop : AgentSource.CodexCLI,
            hook.ProjectName,
            hook.ProjectName,
            null, null, null, [],
            AgentLifecycle.Starting, null,
            now, now, null,
            false, false, false, []);
        task = task with { ProjectName = hook.ProjectName, UpdatedAt = now };
        return hook.HookEventName switch
        {
            CodexHookEventName.SessionStart => task with
            {
                Lifecycle = AgentLifecycle.Starting,
                Activity = AgentActivity.Thinking,
                Capabilities = [],
            },
            CodexHookEventName.UserPromptSubmit => UserPrompt(task, hook.Prompt),
            CodexHookEventName.PreToolUse => task with
            {
                Lifecycle = AgentLifecycle.Running,
                Activity = ActivityFor(hook.ToolName),
                LatestStep = LatestStep(hook.ToolName, hook.ToolInput?.Summary),
                Capabilities = [],
            },
            CodexHookEventName.PostToolUse => task with
            {
                Lifecycle = AgentLifecycle.Running,
                Activity = AgentActivity.Thinking,
                Capabilities = [],
            },
            CodexHookEventName.PermissionRequest => task with
            {
                Lifecycle = AgentLifecycle.WaitingApproval,
                Activity = AgentActivity.Executing,
                Capabilities = [TaskCapability.Approve, TaskCapability.Deny],
            },
            CodexHookEventName.Stop => task with
            {
                Lifecycle = task.Lifecycle == AgentLifecycle.Interrupted
                    ? AgentLifecycle.Interrupted : AgentLifecycle.Succeeded,
                Activity = null,
                CompletedAt = now,
                IsUnread = true,
                Capabilities = [],
            },
            _ => task,
        };
    }

    public static string Title(string projectName, string? prompt)
    {
        var normalized = Normalize(prompt);
        return normalized is null ? projectName : $"{projectName} · {normalized[..Math.Min(34, normalized.Length)]}";
    }

    public static string? LatestStep(string? toolName, string? summary)
    {
        var tool = Normalize(toolName);
        var detail = Normalize(summary);
        if (tool is not null && IsCommandTool(tool))
            return detail is null ? null : detail[..Math.Min(220, detail.Length)];
        var value = (tool, detail) switch
        {
            (not null, not null) => $"{tool} {detail}",
            (not null, null) => tool,
            (null, not null) => detail,
            _ => null,
        };
        return value is null ? null : value[..Math.Min(220, value.Length)];
    }

    public static AgentActivity ActivityFor(string? toolName)
    {
        var name = toolName?.ToLowerInvariant() ?? "";
        if (name.Contains("test") || name.Contains("gradle") || name.Contains("xcode")) return AgentActivity.Testing;
        if (name.Contains("read") || name.Contains("view") || name.Contains("list")) return AgentActivity.Reading;
        if (name.Contains("web") || name.Contains("browser")) return AgentActivity.Browsing;
        if (name.Contains("search") || name.Contains("find") || name.Contains("grep")) return AgentActivity.Searching;
        if (name.Contains("patch") || name.Contains("write") || name.Contains("edit")) return AgentActivity.Editing;
        if (name.Contains("agent") || name.Contains("thread")) return AgentActivity.Delegating;
        return AgentActivity.Executing;
    }

    private static TaskSnapshot UserPrompt(TaskSnapshot task, string? prompt)
    {
        var normalized = Normalize(prompt);
        return task with
        {
            Lifecycle = AgentLifecycle.Running,
            Activity = AgentActivity.Thinking,
            UserPrompt = normalized ?? task.UserPrompt,
            Title = normalized is not null && task.Title == task.ProjectName
                ? Title(task.ProjectName, normalized) : task.Title,
            Capabilities = [],
        };
    }

    private static string? Normalize(string? value)
    {
        if (value is null) return null;
        var result = string.Join(' ', value.Replace('\n', ' ')
            .Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
        return result.Length == 0 ? null : result;
    }

    private static bool IsCommandTool(string value) =>
        new[] { "exec", "exec_command", "terminal_interaction", "bash", "shell", "apply_patch" }
            .Contains(value.Split('.').Last().ToLowerInvariant());
}

public static class ClaudeEventReducer
{
    public static TaskSnapshot Reduce(ClaudeHookPayload hook, TaskSnapshot? existing, DateTimeOffset now)
    {
        var task = existing ?? new(
            hook.SessionID,
            AgentSource.ClaudeCode,
            hook.ProjectName,
            hook.ProjectName,
            null, null, null, [],
            AgentLifecycle.Starting, null,
            now, now, null,
            false, false, false, []);
        task = task with
        {
            ProjectName = hook.ProjectName,
            UpdatedAt = now,
            CompletedAt = null,
            AgentName = AgentIntegrations.DisplayNameFor(hook.IntegrationID),
        };

        switch (hook.HookEventName)
        {
            case "SessionStart":
                return task with
                {
                    Lifecycle = AgentLifecycle.Starting,
                    Activity = AgentActivity.Thinking,
                    CompletedAt = null,
                    Capabilities = [],
                };
            case "UserPromptSubmit":
                return UserPrompt(task, hook.Prompt);
            case "PreToolUse":
                return task with
                {
                    Lifecycle = AgentLifecycle.Running,
                    Activity = CodexEventReducer.ActivityFor(hook.ToolName),
                    LatestStep = CodexEventReducer.LatestStep(hook.ToolName, Summary(hook.ToolInput)),
                    CompletedAt = null,
                    Capabilities = [],
                };
            case "PostToolUse":
            case "PostToolUseFailure":
            case "PreCompact":
                return task with
                {
                    Lifecycle = AgentLifecycle.Running,
                    Activity = AgentActivity.Thinking,
                    CompletedAt = null,
                    Capabilities = [],
                };
            case "PermissionRequest":
                return task with
                {
                    Lifecycle = AgentLifecycle.WaitingApproval,
                    Activity = AgentActivity.Executing,
                    LatestStep = CodexEventReducer.LatestStep(hook.ToolName, Summary(hook.ToolInput)),
                    CompletedAt = null,
                    Capabilities = [TaskCapability.Approve, TaskCapability.Deny],
                };
            case "PermissionDenied":
                return task with
                {
                    Lifecycle = AgentLifecycle.Interrupted,
                    Activity = null,
                    CompletedAt = now,
                    IsUnread = true,
                    Capabilities = [],
                };
            case "Notification":
                // 只有确实等待用户输入的通知才进入等待回答；其他通知保持现有状态。
                return IsAnswerNotification(hook.NotificationType)
                    ? task with
                    {
                        Lifecycle = AgentLifecycle.WaitingAnswer,
                        Activity = AgentActivity.Thinking,
                        CompletedAt = null,
                        Capabilities = [],
                    }
                    : task;
            case "Stop":
                return task with
                {
                    Lifecycle = task.Lifecycle == AgentLifecycle.Interrupted
                        ? AgentLifecycle.Interrupted : AgentLifecycle.Succeeded,
                    Activity = null,
                    CompletedAt = now,
                    IsUnread = true,
                    Capabilities = [],
                };
            case "StopFailure":
                return task with
                {
                    Lifecycle = task.Lifecycle == AgentLifecycle.Succeeded ? AgentLifecycle.Running : task.Lifecycle,
                    CompletedAt = task.Lifecycle == AgentLifecycle.Succeeded ? null : task.CompletedAt,
                    Capabilities = [],
                };
            case "SessionEnd":
                return task with
                {
                    Lifecycle = task.IsTerminal ? task.Lifecycle : AgentLifecycle.Offline,
                    Activity = null,
                    CompletedAt = task.IsTerminal ? task.CompletedAt : null,
                    Capabilities = [],
                };
            case "SubagentStart":
            case "SubagentStop":
                return ApplySubagent(hook, task, now);
            default:
                return task with { UpdatedAt = now };
        }
    }

    /// <summary>从 Claude 的任意 tool_input JSON 中提取最具信息量的字段。</summary>
    public static string? Summary(JsonElement? toolInput)
    {
        if (toolInput is null) return null;
        var value = toolInput.Value;
        if (value.ValueKind != JsonValueKind.Object)
            return DisplayValue(value);
        foreach (var key in new[] { "command", "file_path", "path", "pattern", "query", "prompt", "description", "url" })
        {
            if (value.TryGetProperty(key, out var child) && DisplayValue(child) is { Length: > 0 } text)
                return text;
        }
        return null;
    }

    /// <summary>会让 Claude 暂停并等待用户输入的通知类型。</summary>
    public static bool IsAnswerNotification(string? notificationType) =>
        notificationType is "idle_prompt" or "elicitation_dialog" or "agent_needs_input";

    private static TaskSnapshot ApplySubagent(ClaudeHookPayload hook, TaskSnapshot task, DateTimeOffset now)
    {
        var id = hook.AgentID ?? hook.ToolUseID;
        if (id is null) return task;
        var displayName = !string.IsNullOrWhiteSpace(hook.AgentType) ? hook.AgentType! : "Claude 子代理";
        var path = "/" + (hook.AgentType ?? "subagent");
        var subagent = task.Subagents.FirstOrDefault(value => value.Id == id) ??
            new(id, path, displayName,
                AgentLifecycle.Running, AgentActivity.Thinking,
                null, null, now, now);
        if (hook.HookEventName == "SubagentStart")
        {
            subagent = subagent with
            {
                Lifecycle = AgentLifecycle.Running,
                Activity = AgentActivity.Delegating,
                Path = path,
                DisplayName = displayName,
                LatestStep = Normalize(hook.TaskDescription) ?? subagent.LatestStep,
            };
        }
        else if (hook.HookEventName == "SubagentStop")
        {
            subagent = subagent with { Lifecycle = AgentLifecycle.Succeeded, Activity = null };
        }
        subagent = subagent with { UpdatedAt = now };
        var subagents = task.Subagents.Where(value => value.Id != id).Append(subagent)
            .OrderBy(value => value.IsTerminal).ThenBy(value => value.StartedAt).ToList();
        return task with
        {
            Subagents = subagents,
            Lifecycle = AgentLifecycle.Running,
            Activity = subagents.Any(value => !value.IsTerminal) ? AgentActivity.Delegating : AgentActivity.Thinking,
            UpdatedAt = now,
            CompletedAt = null,
        };
    }

    private static TaskSnapshot UserPrompt(TaskSnapshot task, string? prompt)
    {
        var normalized = Normalize(prompt);
        return task with
        {
            Lifecycle = AgentLifecycle.Running,
            Activity = AgentActivity.Thinking,
            UserPrompt = normalized ?? task.UserPrompt,
            Title = normalized is not null && task.Title == task.ProjectName
                ? CodexEventReducer.Title(task.ProjectName, normalized) : task.Title,
            CompletedAt = null,
            Capabilities = [],
        };
    }

    private static string? DisplayValue(JsonElement value) => value.ValueKind switch
    {
        JsonValueKind.String => value.GetString(),
        JsonValueKind.Number => value.GetRawText(),
        JsonValueKind.True => "true",
        JsonValueKind.False => "false",
        JsonValueKind.Null => "null",
        _ => null,
    };

    private static string? Normalize(string? value)
    {
        if (value is null) return null;
        var result = string.Join(' ', value.Replace('\n', ' ')
            .Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
        return result.Length == 0 ? null : result;
    }
}

public static class ToolStepSanitizer
{
    public static string? Sanitize(string? value)
    {
        if (string.IsNullOrWhiteSpace(value)) return value;
        var result = value.Trim();
        foreach (var prefix in new[] { "functions.", "tools.", "mcp__" })
            if (result.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
                result = result[(result.IndexOf(' ') + 1)..].Trim();
        return result.Length > 220 ? result[..220] : result;
    }
}
