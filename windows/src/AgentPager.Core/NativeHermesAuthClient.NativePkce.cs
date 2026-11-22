using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace AgentPager.Core;

public sealed partial class NativeHermesAuthClient
{
    private async Task<HermesAccountSession> LoginNativeAsync(Uri source, string username, string password, CancellationToken ct)
    {
        static string Url64(byte[] bytes) => Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');
        var verifier = Url64(RandomNumberGenerator.GetBytes(32));
        var challenge = Url64(SHA256.HashData(Encoding.ASCII.GetBytes(verifier)));
        var state = Url64(RandomNumberGenerator.GetBytes(32));
        // The password endpoint returns the broker's redirect as JSON; validate it,
        // but NEVER navigate/fetch this callback or open another listening port.
        var callback = new Uri("http://127.0.0.1:49364/agentpager-auth");
        var authorizePath = "auth/native/authorize?provider=basic&code_challenge_method=S256&code_challenge=" +
            Uri.EscapeDataString(challenge) + "&state=" + Uri.EscapeDataString(state) + "&redirect_uri=" + Uri.EscapeDataString(callback.AbsoluteUri);
        string brokerCookie;
        using (var authorize = await Send(source, authorizePath, null, null, ct, nativeAuthorize: true))
        {
            var location = authorize.Headers.Location;
            if (location is null || !Uri.TryCreate(source, location, out var login) || login != new Uri(source, "login"))
                throw new HermesAuthenticationException("Hermes 原生授权登录地址不匹配，已停止登录。");
            brokerCookie = ExtractBrokerCookie(authorize.Headers.TryGetValues("Set-Cookie", out var headers) ? headers : [], source.Scheme == "https");
        }
        string code;
        using (var passwordResponse = await Send(source, "auth/password-login",
            new { provider = "basic", username, password, next = "/" }, null, ct, brokerCookie))
        using (var document = await Read(passwordResponse, ct))
        {
            var root = document.RootElement;
            if (!root.TryGetProperty("ok", out var ok) || ok.ValueKind != System.Text.Json.JsonValueKind.True)
                throw new HermesAuthenticationException("Hermes 未确认原生登录成功。");
            code = NativeCallbackCode(String(root, "next"), callback, state);
        }
        using var exchange = await Send(source, "auth/native/token", new { code, code_verifier = verifier }, null, ct);
        using var tokenDocument = await Read(exchange, ct);
        var token = tokenDocument.RootElement;
        if (String(token, "token_type") != "Bearer" || String(token, "provider") != "basic")
            throw new HermesAuthenticationException("Hermes 原生令牌响应无效。");
        var session = new HermesAccountSession(String(token, "access_token"), String(token, "refresh_token"), "basic", username, Expiry(token));
        ValidateSession(session);
        return await Verify(source, session.AccessToken, session.RefreshToken, username, ct);
    }

    private static string ExtractBrokerCookie(IEnumerable<string> headers, bool https)
    {
        string? result = null;
        var count = 0; var length = 0;
        foreach (var header in headers)
        {
            if (++count > 32 || (length += header.Length) > MaximumBytes)
                throw new HermesAuthenticationException("原生授权 Cookie 超出大小限制。");
            var pair = header.Split(';', 2)[0].Trim();
            var separator = pair.IndexOf('=');
            if (separator < 1) continue;
            var name = pair[..separator];
            if (!Regex.IsMatch(name, @"^(?:__Host-|__Secure-)?hermes_session_pkce(?:_[0-9a-f]{16})?$", RegexOptions.CultureInvariant)) continue;
            if (result is not null || (!https && (name.StartsWith("__", StringComparison.Ordinal) || header.Split(';').Skip(1).Any(a => a.Trim().Equals("Secure", StringComparison.OrdinalIgnoreCase)))))
                throw new HermesAuthenticationException("原生授权 Cookie 不明确或要求 HTTPS。");
            var value = pair[(separator + 1)..];
            // Treat the broker payload as opaque. Only an exact allowlisted cookie
            // goes to the SAME source's password endpoint; never browser cookies.
            if (value.Length is < 1 or > 8192 || value.Any(c => c <= 0x20 || c >= 0x7f || c is ';' or ','))
                throw new HermesAuthenticationException("原生授权 Cookie 格式无效。");
            result = pair;
        }
        return result ?? throw new HermesAuthenticationException("Hermes 未返回原生授权 Cookie。");
    }

    private static string NativeCallbackCode(string value, Uri expected, string state)
    {
        if (value.Length > 8192 || !Uri.TryCreate(value, UriKind.Absolute, out var next) ||
            next.UserInfo.Length != 0 || next.Fragment.Length != 0 || next.GetLeftPart(UriPartial.Path) != expected.AbsoluteUri)
            throw new HermesAuthenticationException("原生授权回调地址无效。");
        var query = new Dictionary<string,string>(StringComparer.Ordinal);
        foreach (var part in next.Query.TrimStart('?').Split('&'))
        {
            var pair = part.Split('=', 2);
            if (pair.Length != 2 || !query.TryAdd(Uri.UnescapeDataString(pair[0]), Uri.UnescapeDataString(pair[1])))
                throw new HermesAuthenticationException("原生授权回调参数无效。");
        }
        if (query.Count != 2 || !query.TryGetValue("state", out var returned) || returned != state ||
            !query.TryGetValue("code", out var code) || !Regex.IsMatch(code, @"^[A-Za-z0-9_-]{20,256}$", RegexOptions.CultureInvariant))
            throw new HermesAuthenticationException("原生授权状态校验失败。");
        return code;
    }
}
