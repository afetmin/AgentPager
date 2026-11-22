using System.Net;
using System.Text.Json;
using System.Text.RegularExpressions;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Logging;

namespace AgentPager.Bridge;

public sealed record WebMonitorState(bool Enabled, bool Listening, string Status,
    DateTimeOffset? LastBrowserHeartbeatAt, DateTimeOffset? LastDetectionAt,
    string? LastDetectionAction, int TabCount, int ActiveSessionCount, string? LastError,
    int? SidebarRows, int? SpinningRows);

// In-process loopback adapter: only reducer-generated, status-only payloads leave this class.
public sealed class ChatGPTWebMonitorHost : IAsyncDisposable
{
    public const string Token = "apw_1119_8f6db7be5a2a45e2a82f4667240bc921";
    private static readonly Regex ExtensionOrigin = new(
        "\\A(?:chrome-extension://[a-p]{32}|moz-extension://[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12})\\z",
        RegexOptions.CultureInvariant);
    private static readonly HashSet<string> ObservationFields = new(StringComparer.Ordinal)
        { "action", "conversationHash", "previousConversationHash", "requestId", "mode", "title", "observationId", "observedAt", "signal" };
    private readonly object _gate = new();
    private readonly ChatGPTWebStatusTracker _tracker;
    private readonly Func<DateTimeOffset> _clock;
    private readonly int _port;
    private readonly CancellationTokenSource _shutdown = new();
    private WebApplication? _application;
    private Task? _tickTask;
    private bool _enabled;
    private bool _listening;
    private bool _browserSeenSinceEnabled;
    private DateTimeOffset? _lastBrowser;
    private DateTimeOffset? _lastDetection;
    private string? _lastAction;
    private string? _lastError;
    private int _tabs;
    private int? _sidebarRows;
    private int? _spinningRows;

    public ChatGPTWebMonitorHost(Func<Dictionary<string, object>, bool> publish, bool enabled = true,
        int port = 49363, Func<DateTimeOffset>? clock = null)
    {
        _clock = clock ?? (() => DateTimeOffset.UtcNow);
        _tracker = new(publish, () => _clock().UtcDateTime);
        _enabled = enabled;
        _port = port;
    }

    public string? Address { get; private set; }
    public event Action? StateChanged;
    public WebMonitorState State
    {
        get
        {
            lock (_gate)
            {
                var status = !_enabled ? "disabled" : _lastError is not null ? "listener-error" :
                    !_browserSeenSinceEnabled || _lastBrowser is null ? "waiting-browser" : _clock() - _lastBrowser > TimeSpan.FromSeconds(100)
                        ? "browser-offline" : "connected";
                return new(_enabled, _listening, status, _lastBrowser, _lastDetection, _lastAction,
                    _tabs, _tracker.ActiveSessionCount, _lastError, _sidebarRows, _spinningRows);
            }
        }
    }

    public async Task StartAsync(CancellationToken cancellationToken)
    {
        var builder = WebApplication.CreateSlimBuilder(new WebApplicationOptions
            { Args = [], ApplicationName = typeof(ChatGPTWebMonitorHost).Assembly.FullName });
        builder.Logging.ClearProviders();
        builder.WebHost.UseKestrel(options => {
            options.Listen(IPAddress.Loopback, _port);
            options.Limits.MaxRequestBodySize = 16384;
            options.Limits.RequestHeadersTimeout = TimeSpan.FromSeconds(5);
        });
        var app = builder.Build();
        app.Run(HandleHttp);
        try
        {
            await app.StartAsync(cancellationToken);
            _application = app;
            Address = app.Urls.Single();
            lock (_gate) { _listening = true; _lastError = null; }
            _tickTask = TickLoop(_shutdown.Token);
        }
        catch (Exception error)
        {
            lock (_gate) _lastError = $"网页监听启动失败（49363）：{error.GetType().Name}。请关闭旧独立网页桥接程序并重启 Bridge。";
            await app.DisposeAsync();
            NotifyStateChanged();
            throw;
        }
        NotifyStateChanged();
    }

    public void SetEnabled(bool enabled)
    {
        lock (_gate)
        {
            if (_enabled == enabled) return;
            _enabled = enabled;
            if (!enabled) _tracker.StopAll();
            // Old heartbeats cannot make a newly enabled monitor look connected.
            _browserSeenSinceEnabled = false;
            _tabs = 0;
            _sidebarRows = _spinningRows = null;
        }
        NotifyStateChanged();
    }

    public void Tick()
    {
        lock (_gate) if (_enabled) _tracker.Tick();
        NotifyStateChanged();
    }

    private async Task TickLoop(CancellationToken token)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromSeconds(1));
        try { while (await timer.WaitForNextTickAsync(token)) Tick(); }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { }
    }

    private async Task HandleHttp(HttpContext context)
    {
        var origin = context.Request.Headers.Origin.ToString();
        context.Response.Headers.CacheControl = "no-store";
        if (context.Connection.RemoteIpAddress is not { } remote || !IPAddress.IsLoopback(remote) ||
            context.Request.Host.Host != "127.0.0.1" || !ExtensionOrigin.IsMatch(origin))
        {
            context.Response.StatusCode = 403;
            return;
        }
        context.Response.Headers.AccessControlAllowOrigin = origin;
        context.Response.Headers.AccessControlAllowMethods = "POST, GET, OPTIONS";
        context.Response.Headers.AccessControlAllowHeaders = "Content-Type, X-AgentPager-Token";
        context.Response.Headers["Access-Control-Allow-Private-Network"] = "true";
        context.Response.Headers.Vary = "Origin";
        var path = context.Request.Path.Value;
        if (path is not ("/state" or "/status")) { context.Response.StatusCode = 404; return; }
        if (HttpMethods.IsOptions(context.Request.Method)) { context.Response.StatusCode = 204; return; }
        if (context.Request.Headers["X-AgentPager-Token"].ToString() != Token)
        { context.Response.StatusCode = 403; return; }
        if (path == "/status" && HttpMethods.IsGet(context.Request.Method))
        {
            await context.Response.WriteAsJsonAsync(State, cancellationToken: context.RequestAborted);
            return;
        }
        if (path != "/state" || !HttpMethods.IsPost(context.Request.Method))
        { context.Response.StatusCode = 405; return; }
        if (context.Request.ContentLength > 16384)
        {
            // Kestrel cannot drain over-limit bodies for keep-alive reuse. Tell the client
            // to discard this connection before its next legitimate status observation.
            context.Response.Headers.Connection = "close";
            context.Response.StatusCode = 413;
            return;
        }
        if (context.Request.ContentLength is null or < 2 || context.Request.Headers.ContainsKey("Transfer-Encoding"))
        { context.Response.StatusCode = 400; return; }
        Dictionary<string, object>? message;
        try
        {
            message = await JsonSerializer.DeserializeAsync<Dictionary<string, object>>(
                context.Request.Body, cancellationToken: context.RequestAborted);
        }
        catch (JsonException) { context.Response.StatusCode = 400; return; }
        if (message is null) { context.Response.StatusCode = 400; return; }
        bool accepted;
        lock (_gate)
        {
            if (message.TryGetValue("type", out var kind))
            {
                accepted = kind is JsonElement { ValueKind: JsonValueKind.String } element &&
                    element.GetString() == "browser.heartbeat" &&
                    message.Keys.All(key => key is "type" or "tabCount" or "sidebarRows" or "spinningRows") &&
                    ValidRows(message, "sidebarRows") && ValidRows(message, "spinningRows") &&
                    message.TryGetValue("tabCount", out var count) && count is JsonElement { ValueKind: JsonValueKind.Number } tabs &&
                    tabs.TryGetInt32(out var number) && number is >= 0 and <= 10000;
                if (accepted && _enabled)
                {
                    _tabs = ((JsonElement)message["tabCount"]).GetInt32();
                    _sidebarRows = message.TryGetValue("sidebarRows", out var rows) ? ((JsonElement)rows).GetInt32() : null;
                    _spinningRows = message.TryGetValue("spinningRows", out var spinners) ? ((JsonElement)spinners).GetInt32() : null;
                    _lastBrowser = _clock();
                    _browserSeenSinceEnabled = true;
                }
            }
            else
            {
                // Older status-only extensions include a blank legacy prompt key.
                // Remove exactly an empty string before validation; never accept chat text.
                if (message.TryGetValue("prompt", out var prompt) &&
                    prompt is JsonElement { ValueKind: JsonValueKind.String } legacy && legacy.GetString() == "")
                    message.Remove("prompt");
                accepted = message.Keys.All(ObservationFields.Contains) && message.All(pair =>
                    pair.Key == "observedAt" ? pair.Value is JsonElement { ValueKind: JsonValueKind.Number } timestamp &&
                        timestamp.TryGetInt64(out var milliseconds) && milliseconds is >= 0 and <= 9007199254740991 :
                    pair.Value is JsonElement { ValueKind: JsonValueKind.String } text &&
                        (pair.Key != "signal" || text.GetString() is "sidebar-spinner" or "sidebar-idle" or "stop-control" or "composer-idle" or "none") &&
                        (pair.Key != "observationId" || Regex.IsMatch(text.GetString()!, @"\A(?:[\w-]{1,100}:\d{1,16})?\z", RegexOptions.CultureInvariant)));
                if (accepted && _enabled)
                {
                    accepted = _tracker.Accept(message);
                    if (accepted)
                    {
                        _lastBrowser = _clock();
                        _lastDetection = _lastBrowser;
                        _browserSeenSinceEnabled = true;
                        _lastAction = ((JsonElement)message["action"]).GetString();
                    }
                }
            }
        }
        if (accepted) NotifyStateChanged();
        context.Response.StatusCode = accepted ? 200 : 400;
        var state = State;
        await context.Response.WriteAsJsonAsync(new {
            ok = accepted, state.Enabled, state.Listening, state.Status, state.LastBrowserHeartbeatAt,
            state.LastDetectionAt, state.LastDetectionAction, state.TabCount, state.ActiveSessionCount, state.LastError,
            state.SidebarRows, state.SpinningRows
        }, cancellationToken: context.RequestAborted);
    }

    private WebMonitorState? _lastNotified;

    private void NotifyStateChanged()
    {
        lock (_gate)
        {
            var current = State;
            if (current == _lastNotified) return;
            _lastNotified = current;
        }
        StateChanged?.Invoke();
    }

    private static bool ValidRows(Dictionary<string, object> message, string key) =>
        !message.TryGetValue(key, out var value) || value is JsonElement { ValueKind: JsonValueKind.Number } element &&
        element.TryGetInt32(out var number) && number is >= 0 and <= 250;

    public async ValueTask DisposeAsync()
    {
        _shutdown.Cancel();
        if (_tickTask is not null) await _tickTask;
        if (_application is not null)
        {
            await _application.StopAsync();
            await _application.DisposeAsync();
        }
        lock (_gate) _listening = false;
        _shutdown.Dispose();
    }
}
