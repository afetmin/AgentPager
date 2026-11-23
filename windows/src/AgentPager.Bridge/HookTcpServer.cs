using System.Collections.Concurrent;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using AgentPager.Core;

namespace AgentPager.Bridge;

public sealed class HookTcpServer(Func<HookEnvelope, Task> hookHandler, DailyFileLog log)
    : ICodexPermissionResolver, IAsyncDisposable
{
    private readonly ConcurrentDictionary<string, (TcpClient Client, HookSource Source)> _pending = new(StringComparer.Ordinal);
    private TcpListener? _listener;
    private CancellationTokenSource? _cancellation;
    private Task? _acceptTask;

    public void Start()
    {
        _cancellation = new();
        _listener = new(IPAddress.Loopback, 49361);
        _listener.Start();
        _acceptTask = AcceptLoop(_cancellation.Token);
    }

    public bool Resolve(string sessionID, CodexPermissionDecision decision)
    {
        if (!_pending.TryRemove(sessionID, out var entry)) return false;
        try
        {
            using (entry.Client)
            {
                var response = entry.Source == HookSource.Claude
                    ? ClaudeHookOutput.Permission(decision == CodexPermissionDecision.Allow
                        ? ClaudePermissionDecision.Allow
                        : ClaudePermissionDecision.Deny)
                    : CodexHookOutput.Permission(decision);
                entry.Client.GetStream().Write(response);
            }
            return true;
        }
        catch (IOException) { return false; }
    }

    private async Task AcceptLoop(CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested)
        {
            try
            {
                var client = await _listener!.AcceptTcpClientAsync(cancellationToken);
                _ = Handle(client, cancellationToken);
            }
            catch (OperationCanceledException) { break; }
            catch (SocketException error) { log.Write("ERROR", $"Hook accept: {error.Message}"); }
        }
    }

    private async Task Handle(TcpClient client, CancellationToken cancellationToken)
    {
        try
        {
            var stream = client.GetStream();
            using var reader = new StreamReader(stream, Encoding.UTF8, false, 4096, leaveOpen: true);
            var line = await reader.ReadLineAsync(cancellationToken);
            if (line is null) { client.Dispose(); return; }

            var envelope = DecodeEnvelope(line);
            if (envelope is null)
            {
                // 无法识别来源时按 Codex 兼容旧版 CLI；解析失败则放行不阻塞。
                envelope = TryDecodeCodex(line);
            }
            if (envelope is null) { client.Dispose(); return; }

            var isPermission = envelope switch
            {
                HookEnvelope.Codex codex => codex.Hook.HookEventName == CodexHookEventName.PermissionRequest,
                HookEnvelope.Claude claude => claude.Hook.HookEventName == "PermissionRequest",
                _ => false,
            };
            var sessionID = envelope switch
            {
                HookEnvelope.Codex codex => codex.Hook.SessionID,
                HookEnvelope.Claude claude => claude.Hook.SessionID,
                _ => null,
            };
            if (sessionID is null) { client.Dispose(); return; }

            if (isPermission)
            {
                var source = envelope is HookEnvelope.Claude ? HookSource.Claude : HookSource.Codex;
                if (_pending.TryGetValue(sessionID, out var previous)) previous.Client.Dispose();
                _pending[sessionID] = (client, source);
                await hookHandler(envelope);
                return;
            }

            await hookHandler(envelope);
            await stream.WriteAsync("\n"u8.ToArray(), cancellationToken);
            client.Dispose();
        }
        catch (Exception error) when (error is IOException or JsonException or OperationCanceledException)
        {
            client.Dispose();
            log.Write("WARN", $"Hook 请求失败：{error.Message}");
        }
    }

    private static HookEnvelope? DecodeEnvelope(string line)
    {
        JsonObject? root;
        try { root = JsonNode.Parse(line)?.AsObject(); }
        catch { return null; }
        if (root is null) return null;
        if (root["hook_source"]?.GetValue<string>() is not { } rawSource ||
            !Enum.TryParse<HookSource>(rawSource, ignoreCase: true, out var source) ||
            root["payload"] is null)
            return null;

        var payloadNode = root["payload"]!.ToJsonString();
        return source switch
        {
            HookSource.Codex => JsonSerializer.Deserialize<CodexHookPayload>(payloadNode, WireJson.Options) is { } codex
                ? new HookEnvelope.Codex(codex)
                : null,
            HookSource.Claude => DecodeClaude(root, payloadNode),
            _ => null,
        };
    }

    private static HookEnvelope? DecodeClaude(JsonObject root, string payloadNode)
    {
        var agentID = root["agent_id"] is JsonValue value && value.TryGetValue<string>(out var id) ? id : null;
        // 兼容客户端可能混用 camelCase 字段名，先补齐 snake_case 再解码。
        var json = agentID is not null && root["payload"] is JsonObject payload
            ? HookPayloadKeyNormalizer.SnakeCasedKeys(payload).ToJsonString()
            : payloadNode;
        return JsonSerializer.Deserialize<ClaudeHookPayload>(json, WireJson.Options) is { } claude
            ? new HookEnvelope.Claude(claude with { IntegrationID = agentID })
            : null;
    }

    private static HookEnvelope? TryDecodeCodex(string line)
    {
        try
        {
            var payload = JsonSerializer.Deserialize<CodexHookPayload>(line, WireJson.Options);
            return payload is null ? null : new HookEnvelope.Codex(payload);
        }
        catch (JsonException) { return null; }
    }

    public async ValueTask DisposeAsync()
    {
        _cancellation?.Cancel();
        _listener?.Stop();
        foreach (var entry in _pending.Values) entry.Client.Dispose();
        _pending.Clear();
        if (_acceptTask is not null)
            try { await _acceptTask; } catch (OperationCanceledException) { }
        _cancellation?.Dispose();
    }
}
