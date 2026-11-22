using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace AgentPager.Core;

// Never use the generated record ToString for credentials (including debugger/log paths).
public sealed record HermesAccountSession(string AccessToken, string RefreshToken, string Provider, string Username, DateTimeOffset ExpiresAt)
{
    public override string ToString() => "Hermes account session (redacted)";
}

public sealed class HermesAuthenticationException(string message, bool requiresLogin = false) : IOException(message)
{
    public bool RequiresLogin { get; } = requiresLogin;
}

/// <summary>Isolated password login and native refresh. No browser state, redirects, proxies or password retries.</summary>
public sealed partial class NativeHermesAuthClient : IDisposable
{
    public const int MaximumBytes = 65536;
    private readonly HttpClient _http = HermesCredentialTransport.CreateClient(MaximumBytes);

    public async Task<HermesAccountSession> LoginAsync(string url, string username, string password, CancellationToken ct = default)
    {
        var source = NativeHermesUsageClient.ValidateBaseUrl(url);
        HermesCredentialTransport.RequireSecure(source);
        if (string.IsNullOrWhiteSpace(username) || username.Length > 256 || username.Any(char.IsControl) ||
            password.Length is 0 or > 4096) throw new ArgumentException("请输入有效的用户名和密码（用户名最多 256 字符，密码最多 4096 字符）。");
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct);
        deadline.CancelAfter(TimeSpan.FromSeconds(35));
        ct = deadline.Token;
        var supportsNative = false;
        using (var discovery = await Send(source, "api/status", null, null, ct))
        using (var document = await Read(discovery, ct))
        {
            var root = document.RootElement;
            if (!root.TryGetProperty("auth_providers", out var providers) || providers.ValueKind != JsonValueKind.Array ||
                !providers.EnumerateArray().Any(p => p.ValueKind == JsonValueKind.String && p.GetString() == "basic"))
                throw new HermesAuthenticationException("此 Hermes 服务未提供 basic 用户名/密码登录；请检查地址或使用手动令牌。");
            supportsNative = root.TryGetProperty("auth_flows", out var flows) && flows.ValueKind == JsonValueKind.Array &&
                flows.EnumerateArray().Any(p => p.ValueKind == JsonValueKind.String && p.GetString() == "native_pkce");
        }
        // Protected Webapps require registered native tokens, not ordinary browser cookies.
        // A native flow failure must never downgrade or resubmit the user's password.
        if (supportsNative) return await LoginNativeAsync(source, username, password, ct);
        using var response = await Send(source, "auth/password-login", new { provider = "basic", username, password, next = "/" }, null, ct);
        using (var body = await Read(response, ct))
            if (!body.RootElement.TryGetProperty("ok", out var ok) || ok.ValueKind != JsonValueKind.True)
                throw new HermesAuthenticationException("Hermes 未确认登录成功。");
        var (access, refresh) = ExtractSessionCookies(response.Headers.TryGetValues("Set-Cookie", out var cookies) ? cookies : []);
        return await Verify(source, access, refresh, username, ct);
    }

    public async Task<HermesAccountSession> RefreshAsync(string url, HermesAccountSession session, CancellationToken ct = default)
    {
        var source = NativeHermesUsageClient.ValidateBaseUrl(url);
        HermesCredentialTransport.RequireSecure(source);
        ValidateSession(session);
        if (session.RefreshToken.Length == 0) throw new HermesAuthenticationException("会话已过期，请重新登录。", true);
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct);
        deadline.CancelAfter(TimeSpan.FromSeconds(35));
        ct = deadline.Token;
        using var response = await Send(source, "auth/native/refresh", new { refresh_token = session.RefreshToken, provider = session.Provider }, null, ct);
        using var body = await Read(response, ct);
        var root = body.RootElement;
        if (String(root, "token_type") != "Bearer" || String(root, "provider") != "basic")
            throw new HermesAuthenticationException("Hermes 刷新响应无效，请重新登录。", true);
        var candidate = new HermesAccountSession(String(root, "access_token"), String(root, "refresh_token"), "basic", session.Username, Expiry(root));
        ValidateSession(candidate);
        // A JSON token response alone is not evidence the rotated access token works.
        return await Verify(source, candidate.AccessToken, candidate.RefreshToken, session.Username, ct);
    }

    private async Task<HermesAccountSession> Verify(Uri source, string access, string refresh, string username, CancellationToken ct)
    {
        using var response = await Send(source, "api/auth/me", null, access, ct);
        using var body = await Read(response, ct);
        var root = body.RootElement;
        if (String(root, "provider") != "basic") throw new HermesAuthenticationException("无法验证 Hermes 账号会话。", true);
        var session = new HermesAccountSession(access, refresh, "basic", username, Expiry(root));
        ValidateSession(session);
        return session;
    }

    public static void ValidateSession(HermesAccountSession session)
    {
        NativeHermesUsageClient.ValidateToken(session.AccessToken);
        NativeHermesUsageClient.ValidateToken(session.RefreshToken);
        if (session.AccessToken.Length == 0 || session.Provider != "basic" || string.IsNullOrWhiteSpace(session.Username) ||
            session.Username.Length > 256 || session.Username.Any(char.IsControl) || session.ExpiresAt <= DateTimeOffset.UnixEpoch)
            throw new HermesAuthenticationException("Hermes 账号会话无效，请重新登录。", true);
    }

    public static (string Access, string Refresh) ExtractSessionCookies(IEnumerable<string> headers)
    {
        string? access = null, refresh = null, variant = null;
        var count = 0;
        var total = 0;
        foreach (var header in headers)
        {
            if (++count > 32 || (total += header.Length) > MaximumBytes) throw new HermesAuthenticationException("登录 Cookie 超出大小限制。");
            var pair = header.Split(';', 2)[0];
            var split = pair.IndexOf('=');
            if (split <= 0) continue;
            var name = pair[..split].Trim();
            // Gateway suffix is a SHA256 hex digest of the gateway home, currently truncated to 16 chars.
            var match = Regex.Match(name, @"^(?<prefix>__Host-|__Secure-)?hermes_session_(?<kind>at|rt)(?<suffix>_[0-9a-f]{16})?$", RegexOptions.CultureInvariant);
            if (!match.Success) continue;
            var value = pair[(split + 1)..].Trim();
            if (value.Length >= 2 && value[0] == '"' && value[^1] == '"') value = value[1..^1];
            NativeHermesUsageClient.ValidateToken(value);
            if (value.Length == 0) throw new HermesAuthenticationException("登录未返回有效会话 Cookie。");
            var currentVariant = match.Groups["prefix"].Value + match.Groups["suffix"].Value;
            if (variant is not null && variant != currentVariant) throw new HermesAuthenticationException("登录返回了不明确的会话 Cookie。");
            variant = currentVariant;
            if (match.Groups["kind"].Value == "at")
            { if (access is not null) throw new HermesAuthenticationException("登录返回重复会话 Cookie。"); access = value; }
            else
            { if (refresh is not null) throw new HermesAuthenticationException("登录返回重复会话 Cookie。"); refresh = value; }
        }
        if (access is null) throw new HermesAuthenticationException("登录未返回受支持的会话 Cookie。");
        return (access, refresh ?? "");
    }

    private async Task<HttpResponseMessage> Send(Uri source, string path, object? payload, string? bearer, CancellationToken ct,
        string? brokerCookie = null, bool nativeAuthorize = false)
    {
        using var request = new HttpRequestMessage(payload is null ? HttpMethod.Get : HttpMethod.Post, new Uri(source, path));
        request.Headers.Accept.ParseAdd("application/json");
        request.Headers.CacheControl = new CacheControlHeaderValue { NoStore = true };
        if (bearer is not null) request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", bearer);
        if (brokerCookie is not null) request.Headers.TryAddWithoutValidation("Cookie", brokerCookie);
        if (payload is not null) request.Content = JsonContent.Create(payload);
        var response = await _http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, ct).ConfigureAwait(false);
        if (nativeAuthorize ? response.StatusCode == HttpStatusCode.Found : response.StatusCode == HttpStatusCode.OK) return response;
        var status = response.StatusCode;
        response.Dispose();
        // Deliberately never include URL, response body, exception text, username or any token.
        throw status switch {
            HttpStatusCode.Unauthorized => new HermesAuthenticationException("用户名或密码错误，或会话已过期；请重新登录。", true),
            HttpStatusCode.TooManyRequests => new HermesAuthenticationException("登录请求过于频繁（429），请稍后手动重试。"),
            HttpStatusCode.NotFound => new HermesAuthenticationException("此服务不支持所需认证接口；请检查 Hermes 地址。"),
            _ => new HermesAuthenticationException("Hermes 认证服务不可用或拒绝重定向；请检查网络和服务地址。")
        };
    }

    private static async Task<JsonDocument> Read(HttpResponseMessage response, CancellationToken ct)
    {
        if (response.Content.Headers.ContentLength > MaximumBytes) throw new HermesAuthenticationException("认证响应超出大小限制。");
        await using var stream = await response.Content.ReadAsStreamAsync(ct);
        using var buffer = new MemoryStream();
        var block = new byte[4096];
        int n;
        while ((n = await stream.ReadAsync(block, ct)) != 0)
        {
            if (buffer.Length + n > MaximumBytes) throw new HermesAuthenticationException("认证响应超出大小限制。");
            buffer.Write(block, 0, n);
        }
        return JsonDocument.Parse(buffer.ToArray(), new JsonDocumentOptions { MaxDepth = 12 });
    }
    private static string String(JsonElement root, string name) => root.GetProperty(name).GetString() ?? throw new FormatException("认证响应无效。");
    private static DateTimeOffset Expiry(JsonElement root)
    {
        var value = root.GetProperty("expires_at").GetDouble();
        var now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        if (!double.IsFinite(value) || value <= now || value > now + TimeSpan.FromDays(366).TotalSeconds)
            throw new HermesAuthenticationException("Hermes 返回的会话有效期无效，请重新登录。", true);
        return DateTimeOffset.FromUnixTimeSeconds((long)value);
    }
    public void Dispose() => _http.Dispose();
}
