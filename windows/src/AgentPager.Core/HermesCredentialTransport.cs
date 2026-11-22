using System.Net;
using System.Net.Sockets;

namespace AgentPager.Core;

public static class HermesCredentialTransport
{
    public const string HttpsRequiredMessage = "Hermes 账号登录和令牌仅允许通过 HTTPS 或本机回环 HTTP。请将服务 URL 改为 HTTPS 后重新登录或录入令牌；如果服务允许匿名访问，可清除令牌后使用 HTTP。";

    public static bool AllowsCredentials(Uri source) => source.Scheme == Uri.UriSchemeHttps ||
        (source.Scheme == Uri.UriSchemeHttp && (IsLocalhost(source.IdnHost) || LoopbackAddress(source.IdnHost) is not null));

    public static void RequireSecure(Uri source)
    {
        if (!AllowsCredentials(source)) throw new HermesAuthenticationException(HttpsRequiredMessage);
    }

    internal static HttpClient CreateClient(int maximumBytes) => new(new SocketsHttpHandler
    {
        AllowAutoRedirect = false, UseCookies = false, UseProxy = false,
        AutomaticDecompression = DecompressionMethods.None, MaxResponseHeadersLength = 64,
        ConnectCallback = ConnectAsync,
    }) { Timeout = TimeSpan.FromSeconds(15), MaxResponseContentBufferSize = maximumBytes };

    private static bool IsLocalhost(string host) => host.Equals("localhost", StringComparison.OrdinalIgnoreCase) ||
        host.Equals("localhost.", StringComparison.OrdinalIgnoreCase);

    private static IPAddress? LoopbackAddress(string host)
    {
        if (!IPAddress.TryParse(host, out var ip)) return null;
        return IPAddress.IsLoopback(ip.IsIPv4MappedToIPv6 ? ip.MapToIPv4() : ip) ? ip : null;
    }

    private static async ValueTask<Stream> ConnectAsync(SocketsHttpConnectionContext context, CancellationToken ct)
    {
        var endpoint = context.DnsEndPoint;
        var source = context.InitialRequestMessage.RequestUri;
        var socket = new Socket(SocketType.Stream, ProtocolType.Tcp) { NoDelay = true };
        try
        {
            // Never rely on DNS or the hosts file for the plaintext loopback exception.
            // Keep the original request URI/Host header; only pin the socket destination.
            if (source is { Scheme: "http" } && IsLocalhost(source.IdnHost))
            {
                IPAddress[] loopback = Socket.OSSupportsIPv6 ? [IPAddress.Loopback, IPAddress.IPv6Loopback] : [IPAddress.Loopback];
                await socket.ConnectAsync(loopback, endpoint.Port, ct).ConfigureAwait(false);
            }
            else if (source is { Scheme: "http" } && LoopbackAddress(source.IdnHost) is { } ip)
                await socket.ConnectAsync(new IPEndPoint(ip, endpoint.Port), ct).ConfigureAwait(false);
            else
                await socket.ConnectAsync(endpoint, ct).ConfigureAwait(false);
            return new NetworkStream(socket, ownsSocket: true);
        }
        catch
        {
            socket.Dispose();
            throw;
        }
    }
}
