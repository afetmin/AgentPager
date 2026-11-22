using System.Net.WebSockets;
using System.Reflection;
using AgentPager.Bridge;

internal static class WebSocketShutdownTests
{
    public static async Task Run()
    {
        var type = typeof(LanBridgeServer).GetNestedType("Client", BindingFlags.NonPublic)!;
        var socket = new CompletedResponseSocket();
        var client = (IAsyncDisposable)Activator.CreateInstance(type, BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Instance,
            null, [socket], null)!;
        await client.DisposeAsync();
        if (!socket.Disposed) throw new Exception("A completed HTTP response must not prevent socket cleanup");
        Console.WriteLine("PASS socket cleanup tolerates canceled close after HTTP response completion");
    }
    private sealed class CompletedResponseSocket : WebSocket
    {
        public bool Disposed;
        public override WebSocketCloseStatus? CloseStatus => null;
        public override string? CloseStatusDescription => null;
        public override WebSocketState State => WebSocketState.Open;
        public override string? SubProtocol => null;
        public override void Abort() { }
        public override Task CloseAsync(WebSocketCloseStatus closeStatus, string? statusDescription, CancellationToken cancellationToken) =>
            Task.FromException(new OperationCanceledException("HTTP response completed", new ObjectDisposedException("HttpResponseStream")));
        public override Task CloseOutputAsync(WebSocketCloseStatus closeStatus, string? statusDescription, CancellationToken cancellationToken) => Task.CompletedTask;
        public override void Dispose() => Disposed = true;
        public override Task<WebSocketReceiveResult> ReceiveAsync(ArraySegment<byte> buffer, CancellationToken cancellationToken) => throw new NotSupportedException();
        public override Task SendAsync(ArraySegment<byte> buffer, WebSocketMessageType messageType, bool endOfMessage, CancellationToken cancellationToken) => throw new NotSupportedException();
    }
}
