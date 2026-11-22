using System.Collections.Concurrent;
using System.Net;
using System.Net.WebSockets;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using AgentPager.Core;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;

namespace AgentPager.Bridge;

public sealed class LanBridgeServer(
    X509Certificate2 certificate,
    byte[] pairingSecret,
    Func<string> snapshotProvider,
    Func<string, Task> messageHandler,
    Action<int> countChanged,
    DailyFileLog log,
    string hermesToken,
    Action<HermesHeartbeat> hermesHeartbeat,
    bool loopbackOnly = false) : IAsyncDisposable
{
    internal const ushort PhonePort = 49365;
    private const ushort HermesIngressPort = 49362;
    private const int MaximumControlBytes = 1024 * 1024;
    private readonly byte[] _authorization = Encoding.ASCII.GetBytes("Bearer " + Convert.ToBase64String(pairingSecret));

    private sealed class Client(WebSocket socket) : IAsyncDisposable
    {
        private readonly SemaphoreSlim _sendLock = new(1, 1);
        public WebSocket Socket { get; } = socket;

        public async Task Send(string text, CancellationToken cancellationToken = default)
        {
            await _sendLock.WaitAsync(cancellationToken);
            try
            {
                if (Socket.State == WebSocketState.Open)
                    await Socket.SendAsync(Encoding.UTF8.GetBytes(text), WebSocketMessageType.Text, true, cancellationToken);
            }
            finally { _sendLock.Release(); }
        }

        public async ValueTask DisposeAsync()
        {
            if (Socket.State is WebSocketState.Open or WebSocketState.CloseReceived)
                try
                {
                    using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(2));
                    await Socket.CloseAsync(WebSocketCloseStatus.NormalClosure, "Bridge shutdown", timeout.Token);
                }
                catch (Exception error) when (error is WebSocketException or OperationCanceledException or ObjectDisposedException or IOException) { }
            Socket.Dispose();
        }
    }

    private readonly ConcurrentDictionary<Guid, Client> _clients = [];
    private WebApplication? _application;

    public int ClientCount => _clients.Count;

    public async Task StartAsync(CancellationToken cancellationToken)
    {
        var options = new WebApplicationOptions { Args = [], ApplicationName = typeof(LanBridgeServer).Assembly.FullName };
        var builder = WebApplication.CreateSlimBuilder(options);
        builder.Logging.ClearProviders();
        builder.WebHost.ConfigureKestrel(server =>
        {
            server.Listen(IPAddress.Loopback, HermesIngressPort);
            server.Listen(loopbackOnly ? IPAddress.Loopback : IPAddress.Any, PhonePort,
                listener => listener.UseHttps(certificate));
        });
        builder.Services.AddRouting();
        var app = builder.Build();
        app.UseWebSockets(new WebSocketOptions { KeepAliveInterval = TimeSpan.FromSeconds(20) });

        app.Use(async (context, next) =>
        {
            if ((context.Request.IsHttps && context.Connection.LocalPort == PhonePort && context.Request.Path == "/agentgrid") ||
                (!context.Request.IsHttps && context.Connection.LocalPort == HermesIngressPort && context.Request.Path == "/hermes-status"))
            {
                await next(context);
                return;
            }
            context.Response.StatusCode = StatusCodes.Status404NotFound;
        });

        app.MapHermesStatus(hermesToken, hermesHeartbeat);
        app.Map("/agentgrid", HandleWebSocket);
        try { await app.StartAsync(cancellationToken); }
        catch { await app.DisposeAsync(); throw; }
        _application = app;
    }

    public async Task BroadcastAsync(string text)
    {
        foreach (var pair in _clients.ToList())
        {
            try { await pair.Value.Send(text); }
            catch (Exception error) when (error is WebSocketException or OperationCanceledException)
            {
                await Remove(pair.Key);
            }
        }
    }

    private async Task HandleWebSocket(HttpContext context)
    {
        // The phone is a native client, not a browser; reject browser-origin upgrades.
        if (context.Request.Headers.ContainsKey("Origin"))
        {
            context.Response.StatusCode = StatusCodes.Status403Forbidden;
            return;
        }
        var authorization = context.Request.Headers.Authorization;
        if (authorization.Count != 1 || authorization[0] is not { } value ||
            value.Length != _authorization.Length ||
            !CryptographicOperations.FixedTimeEquals(Encoding.UTF8.GetBytes(value), _authorization))
        {
            context.Response.StatusCode = StatusCodes.Status401Unauthorized;
            return;
        }
        if (!context.WebSockets.IsWebSocketRequest)
        {
            context.Response.StatusCode = StatusCodes.Status400BadRequest;
            return;
        }
        var socket = await context.WebSockets.AcceptWebSocketAsync();
        var id = Guid.NewGuid();
        var client = new Client(socket);
        _clients[id] = client;
        countChanged(_clients.Count);
        try
        {
            await client.Send(snapshotProvider(), context.RequestAborted);
            var buffer = new byte[64 * 1024];
            using var message = new MemoryStream();
            while (socket.State == WebSocketState.Open)
            {
                var result = await socket.ReceiveAsync(buffer, context.RequestAborted);
                if (result.MessageType == WebSocketMessageType.Close) break;
                if (result.MessageType != WebSocketMessageType.Text || message.Length + result.Count > MaximumControlBytes) break;
                await message.WriteAsync(buffer.AsMemory(0, result.Count), context.RequestAborted);
                if (!result.EndOfMessage) continue;

                var text = Encoding.UTF8.GetString(message.ToArray());
                message.SetLength(0);
                await messageHandler(text);
            }
        }
        catch (Exception error) when (error is WebSocketException or OperationCanceledException or IOException)
        {
            log.Write("WARN", $"WebSocket 关闭：{error.Message}");
        }
        finally { await Remove(id); }
    }

    private async Task Remove(Guid id)
    {
        if (_clients.TryRemove(id, out var client))
        {
            await client.DisposeAsync();
            countChanged(_clients.Count);
        }
    }

    public async ValueTask DisposeAsync()
    {
        foreach (var id in _clients.Keys.ToList()) await Remove(id);
        if (_application is not null)
        {
            await _application.StopAsync();
            await _application.DisposeAsync();
        }
    }
}
