using System.Net;
using System.Text.Json;
using AgentPager.Core;
using AgentPager.Bridge;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Logging;

internal static class HermesAuthTests
{
    internal static void Check(bool condition, string message) { if (!condition) throw new Exception(message); }
    public static async Task Run()
    {
        var builder = WebApplication.CreateSlimBuilder();
        builder.Logging.ClearProviders();
        builder.WebHost.UseUrls("http://127.0.0.1:0");
        await using var app = builder.Build();
        var passwordCalls = 0;
        app.MapGet("/base/api/status", () => Results.Json(new { auth_required = true, auth_providers = new[] { "basic" } }));
        app.MapPost("/base/auth/password-login", async context =>
        {
            passwordCalls++;
            Check(context.Request.Headers.Cookie.Count == 0 && context.Request.Headers.Authorization.Count == 0, "Login must not borrow cookies or bearer");
            using var body = await JsonDocument.ParseAsync(context.Request.Body);
            var root = body.RootElement;
            Check(root.GetProperty("provider").GetString() == "basic" && root.GetProperty("username").GetString() == "fixture-user" &&
                root.GetProperty("password").GetString() == "fixture-password" && root.GetProperty("next").GetString() == "/", "Password protocol mismatch");
            context.Response.Headers.Append("Set-Cookie", "hermes_session_at=fixture-access; HttpOnly; Path=/base; SameSite=Lax");
            context.Response.Headers.Append("Set-Cookie", "hermes_session_rt=fixture-refresh; HttpOnly; Path=/base; SameSite=Lax");
            context.Response.Headers.Append("Set-Cookie", "other_secret=ignored; Path=/");
            await context.Response.WriteAsJsonAsync(new { ok = true, next = "http://127.0.0.1:1/do-not-follow" });
        });
        app.MapPost("/base/auth/native/refresh", async context =>
        {
            Check(context.Request.Headers.Cookie.Count == 0 && context.Request.Headers.Authorization.Count == 0, "Refresh borrows browser auth");
            using var document = await JsonDocument.ParseAsync(context.Request.Body);
            Check(document.RootElement.GetProperty("refresh_token").GetString() == "fixture-refresh" && document.RootElement.GetProperty("provider").GetString() == "basic", "Refresh protocol mismatch");
            await context.Response.WriteAsJsonAsync(new { access_token = "fixture-rotated", refresh_token = "fixture-refresh-rotated", token_type = "Bearer", provider = "basic", user_id = "fixture-user", expires_at = DateTimeOffset.UtcNow.AddMinutes(10).ToUnixTimeSeconds() });
        });
        app.MapGet("/base/api/auth/me", (HttpRequest request) =>
        {
            Check((request.Headers.Authorization == "Bearer fixture-access" || request.Headers.Authorization == "Bearer fixture-rotated") && request.Headers.Cookie.Count == 0, "Must verify cookie token as isolated bearer");
            return Results.Json(new { provider = "basic", user_id = "fixture-user", display_name = "Fixture", expires_at = DateTimeOffset.UtcNow.AddSeconds(request.Headers.Authorization == "Bearer fixture-access" ? 30 : 600).ToUnixTimeSeconds() });
        });
        app.MapGet("/base/api/analytics/{kind}", (HttpRequest request, string kind) =>
        {
            Check(request.Headers.Authorization == "Bearer fixture-rotated" && request.Headers.Cookie.Count == 0, "Background analytics must use durable rotated access token");
            return kind == "usage" ? Results.Json(new { period_days = 90, daily = Array.Empty<object>() }) :
                Results.Json(new { period_days = int.Parse(request.Query["days"]!), models = Array.Empty<object>() });
        });
        await app.StartAsync();
        using var auth = new NativeHermesAuthClient();
        var session = await auth.LoginAsync(app.Urls.Single() + "/base", "fixture-user", "fixture-password");
        Check(session.AccessToken == "fixture-access" && session.RefreshToken == "fixture-refresh" && session.Username == "fixture-user" && session.Provider == "basic", "Verified session missing");
        Check(passwordCalls == 1, "Password login must never auto-retry");
        Console.WriteLine("PASS account login actual HTTP client: basic discovery, JSON password protocol, allowlisted cookie extraction, bearer verification, ignored next and no cookies");
        ProtectedSessions(session);
        await RuntimeSessions(app.Urls.Single() + "/base");
        await HermesAuthSafetyTests.Run();
        await HermesNativePkceTests.Run();
    }

    private static async Task RuntimeSessions(string url)
    {
        var path = Path.Combine(AgentPagerPaths.DataRoot, "runtime-account.bin");
        var key = System.Security.Cryptography.RandomNumberGenerator.GetBytes(32);
        byte[] Encrypt(byte[] plain) { using var aes = System.Security.Cryptography.Aes.Create(); aes.Key = key; return aes.IV.Concat(aes.EncryptCbc(plain, aes.IV)).ToArray(); }
        byte[] Decrypt(byte[] data) { using var aes = System.Security.Cryptography.Aes.Create(); aes.Key = key; return aes.DecryptCbc(data.AsSpan(16), data.AsSpan(0, 16)); }
        var store = new HermesAccessTokenStore(path, Encrypt, Decrypt);
        await using var runtime = new BridgeRuntime(new BridgeSettings { LaunchAtLogin = false }, new byte[32], true, store);
        var preflight = await runtime.LoginHermesAsync(url, "profile 中文", "fixture-user", "fixture-password");
        Check(preflight.Ok, "Preflight login failed");
        var oldBytes = store.ReadProtected();
        var settingsPath = AgentPagerPaths.SettingsFile;
        File.Move(settingsPath, settingsPath + ".auth-backup");
        Directory.CreateDirectory(settingsPath);
        try
        {
            var failed = await runtime.LoginHermesAsync(url, "changed-profile", "fixture-user", "fixture-password");
            Check(!failed.Ok && runtime.Settings.HermesProfile == "profile 中文" && store.ReadProtected()!.SequenceEqual(oldBytes!), "Login settings failure did not roll back session/source atomically");
        }
        finally { Directory.Delete(settingsPath); File.Move(settingsPath + ".auth-backup", settingsPath); }
        var result = await runtime.LoginHermesAsync(url, "profile 中文", "fixture-user", "fixture-password");
        Check(result.Ok && runtime.HermesSignedInUsername == "fixture-user" && runtime.HasHermesAccessToken, "Runtime did not commit verified account login: " + result.Error);
        Check(runtime.NativeHermesStatus.Contains("HTTP 明文") && runtime.NativeHermesStatus.Contains("HTTPS"), "HTTP source must retain an explicit plaintext warning");
        var canonical = NativeHermesUsageClient.ValidateBaseUrl(url).AbsoluteUri;
        Check(BridgeSettings.Load().HermesServiceUrl == canonical && BridgeSettings.Load().HermesProfile == "profile 中文", "Login failed settings readback");
        var tokens = await Task.WhenAll(Enumerable.Range(0, 8).Select(_ => runtime.GetHermesAccessTokenAsync(canonical, "profile 中文", runtime.HermesSourceRevision, CancellationToken.None)));
        Check(tokens.All(t => t == "fixture-rotated") && store.LoadSession(canonical, "profile 中文")?.RefreshToken == "fixture-refresh-rotated", "Oneflight refresh did not atomically persist rotated pair");
        await using (var restarted = new BridgeRuntime(BridgeSettings.Load(), new byte[32], true, store))
            Check(restarted.HermesSignedInUsername == "fixture-user", "Account identity failed restart");
        // Force the next real background pull through the expiry/refresh path as well.
        store.SaveSession(canonical, "profile 中文", new("fixture-access", "fixture-refresh", "basic", "fixture-user", DateTimeOffset.UtcNow.AddSeconds(30)));
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(15));
        await runtime.StartAsync(deadline.Token, startWebListener: false);
        using var socket = await PhoneFixture.ConnectAsync(runtime, deadline.Token);
        while (true)
        {
            using var bytes = new MemoryStream();
            var buffer = new byte[32768];
            System.Net.WebSockets.WebSocketReceiveResult frame;
            do { frame = await socket.ReceiveAsync(buffer, deadline.Token); bytes.Write(buffer, 0, frame.Count); } while (!frame.EndOfMessage);
            var wire = System.Text.Encoding.UTF8.GetString(bytes.ToArray());
            Check(!wire.Contains("fixture-user") && !wire.Contains("fixture-access") && !wire.Contains("fixture-rotated") && !wire.Contains("fixture-refresh") && !wire.Contains("fixture-password"), "Account secret or identity leaked to phone");
            using var parsed = JsonDocument.Parse(wire);
            if (parsed.RootElement.GetProperty("payload").TryGetProperty("hermesUsage", out _)) break;
        }
        socket.Abort();
        deadline.Cancel();
        Check(runtime.LogoutHermes(out var error) && runtime.HermesSignedInUsername is null && !runtime.HasHermesAccessToken && !File.Exists(path), "Local logout did not delete session: " + error);
        Check(runtime.Settings.HermesServiceUrl == canonical && runtime.Settings.HermesProfile == "profile 中文" && !runtime.Settings.HermesAllowAnonymous, "Logout must preserve source but never enable anonymity");
        Check(!File.ReadAllText(AgentPagerPaths.SettingsFile).Contains("fixture-password"), "Password persisted in preferences");
        Console.WriteLine("PASS runtime account login + protected restart + concurrent refresh rotation + local logout preserving source");
    }

    private static void ProtectedSessions(HermesAccountSession session)
    {
        var path = Path.Combine(Environment.GetEnvironmentVariable("AGENTPAGER_AUTH_TEST_ROOT") ?? Path.GetTempPath(), "account-session-" + Guid.NewGuid().ToString("N") + ".bin");
        var key = System.Security.Cryptography.RandomNumberGenerator.GetBytes(32);
        byte[] Encrypt(byte[] plain) { using var aes = System.Security.Cryptography.Aes.Create(); aes.Key = key; return aes.IV.Concat(aes.EncryptCbc(plain, aes.IV)).ToArray(); }
        byte[] Decrypt(byte[] data) { using var aes = System.Security.Cryptography.Aes.Create(); aes.Key = key; return aes.DecryptCbc(data.AsSpan(16), data.AsSpan(0, 16)); }
        try
        {
            var store = new HermesAccessTokenStore(path, Encrypt, Decrypt);
            store.SaveSession("http://localhost:9119/base/", "profile", session);
            var read = new HermesAccessTokenStore(path, Encrypt, Decrypt).LoadSession("http://localhost:9119/base/", "profile");
            Check(read == session && store.Load("http://localhost:9119/base/", "profile") == session.AccessToken, "Account session failed protected restart roundtrip");
            Check(store.LoadSession("http://localhost:9119/other/", "profile") is null && store.LoadSession("http://localhost:9119/base/", "other") is null, "Account credentials escaped exact source binding");
            var disk = System.Text.Encoding.UTF8.GetString(File.ReadAllBytes(path));
            Check(!disk.Contains(session.AccessToken) && !disk.Contains(session.RefreshToken) && !disk.Contains(session.Username), "Session plaintext persisted");
            store.Save("http://localhost:9119/base/", "fixture-manual", "profile");
            Check(store.LoadSession("http://localhost:9119/base/", "profile") is null && store.Load("http://localhost:9119/base/", "profile") == "fixture-manual", "Legacy manual-token compatibility broken");
            var old = File.ReadAllBytes(path);
            var failing = new HermesAccessTokenStore(path, _ => throw new System.Security.Cryptography.CryptographicException(), Decrypt);
            try { failing.SaveSession("http://localhost:9119/base/", "profile", session); throw new Exception("Failed encryption accepted"); }
            catch (System.Security.Cryptography.CryptographicException) { }
            Check(File.ReadAllBytes(path).SequenceEqual(old), "Encryption failure damaged existing credential");
            File.WriteAllBytes(path, [1, 2, 3]);
            try { store.LoadSession("http://localhost:9119/base/", "profile"); throw new Exception("Corrupt session accepted"); }
            catch (System.Security.Cryptography.CryptographicException) { }
            Console.WriteLine("PASS account session protected persistence: injected cipher, restart, exact URL/profile, legacy manual token, failure/corruption and no plaintext");
        }
        finally { File.Delete(path); }
    }
}
