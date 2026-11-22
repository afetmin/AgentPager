using AgentPager.Bridge;
using AgentPager.Core;
using System.Text.Json;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Logging;
using static HermesAuthTests;

internal static class HermesAuthSafetyTests
{
    public static async Task Run()
    {
        Cookies();
        var builder = WebApplication.CreateSlimBuilder();
        builder.Logging.ClearProviders();
        builder.WebHost.UseUrls("http://127.0.0.1:0");
        await using var app = builder.Build();
        var passwordCalls = 0;
        var redirects = 0;
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var refreshEntered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var refreshRelease = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        app.MapGet("/leak", () => { redirects++; return "must not follow"; });
        app.MapGet("/{mode}/api/status", (string mode) => Results.Json(new { auth_required = true, auth_providers = mode == "missing" ? new[] { "nous" } : new[] { "basic" } }));
        app.MapPost("/{mode}/auth/password-login", async context =>
        {
            passwordCalls++;
            var mode = context.Request.RouteValues["mode"]!.ToString();
            if (mode == "bad") { context.Response.StatusCode = 401; await context.Response.WriteAsync("fixture-password-must-not-echo"); return; }
            if (mode == "rate") { context.Response.StatusCode = 429; return; }
            if (mode == "redirect") { context.Response.StatusCode = 307; context.Response.Headers.Location = "/leak"; return; }
            if (mode == "slow") { await Task.Delay(10000, context.RequestAborted); return; }
            if (mode == "large") { await context.Response.WriteAsync(new string(' ', NativeHermesAuthClient.MaximumBytes + 1)); return; }
            if (mode == "pending") { entered.TrySetResult(); await release.Task.WaitAsync(context.RequestAborted); }
            context.Response.Headers.Append("Set-Cookie", "hermes_session_at=fixture-access; Path=/; HttpOnly");
            context.Response.Headers.Append("Set-Cookie", "hermes_session_rt=fixture-refresh; Path=/; HttpOnly");
            await context.Response.WriteAsJsonAsync(new { ok = true, next = "/leak" });
        });
        app.MapGet("/{mode}/api/auth/me", (string mode) => mode == "unverified" ? Results.Unauthorized() :
            Results.Json(new { provider = "basic", user_id = "fixture-user", expires_at = DateTimeOffset.UtcNow.AddMinutes(10).ToUnixTimeSeconds() }));
        app.MapPost("/{mode}/auth/native/refresh", async context =>
        {
            var mode = context.Request.RouteValues["mode"]!.ToString();
            if (mode == "refreshbad") { context.Response.StatusCode = 401; return; }
            if (mode == "refreshpending") { refreshEntered.TrySetResult(); await refreshRelease.Task.WaitAsync(context.RequestAborted); }
            await context.Response.WriteAsJsonAsync(new { access_token = "fixture-rotated", refresh_token = "fixture-rotated-refresh", provider = "basic", token_type = "Bearer", expires_at = DateTimeOffset.UtcNow.AddMinutes(10).ToUnixTimeSeconds() });
        });
        app.MapGet("/{mode}/api/analytics/{kind}", () => Results.Unauthorized());
        await app.StartAsync();
        var endpoint = app.Urls.Single();
        using var auth = new NativeHermesAuthClient();
        foreach (var mode in new[] { "missing", "bad", "rate", "redirect", "large", "unverified" })
        {
            var before = passwordCalls;
            try { await auth.LoginAsync(endpoint + "/" + mode, "fixture-user", "fixture-password-must-not-echo"); throw new Exception("Unsafe auth accepted: " + mode); }
            catch (Exception e) when (e is HermesAuthenticationException or JsonException)
            { Check(!e.Message.Contains("fixture-"), "Credential echoed from auth failure"); }
            Check(passwordCalls - before == (mode == "missing" ? 0 : 1), "Password submitted more than once");
        }
        using (var ct = new CancellationTokenSource(TimeSpan.FromMilliseconds(150)))
        {
            try { await auth.LoginAsync(endpoint + "/slow", "fixture-user", "fixture-password", ct.Token); throw new Exception("Cancellation ignored"); }
            catch (OperationCanceledException) { }
        }
        Check(redirects == 0, "Auth followed redirect/next");
        try { await auth.LoginAsync("http://127.0.0.1:1/", "fixture-user", "fixture-password"); throw new Exception("Unreachable auth accepted"); }
        catch (System.Net.Http.HttpRequestException) { }
        Console.WriteLine("PASS actual auth HTTP failures: missing basic, bad credentials401, rate429, redirect refusal, response bound, verification rejection, cancel, unreachable, no password retry");
        var key = System.Security.Cryptography.RandomNumberGenerator.GetBytes(32);
        var failSave = false;
        byte[] Encrypt(byte[] plain) { if (failSave) throw new System.Security.Cryptography.CryptographicException(); using var aes = System.Security.Cryptography.Aes.Create(); aes.Key = key; return aes.IV.Concat(aes.EncryptCbc(plain, aes.IV)).ToArray(); }
        byte[] Decrypt(byte[] data) { using var aes = System.Security.Cryptography.Aes.Create(); aes.Key = key; return aes.DecryptCbc(data.AsSpan(16), data.AsSpan(0, 16)); }
        var path = Path.Combine(AgentPagerPaths.DataRoot, "safety-session.bin");
        var store = new HermesAccessTokenStore(path, Encrypt, Decrypt);
        const string oldInsecureSource = "http://192.0.2.15/dashboard/";
        foreach (var storedAccount in new[] { false, true })
        {
            if (storedAccount)
                store.SaveSession(oldInsecureSource, null, new("fixture-access", "fixture-refresh", "basic", "fixture-user", DateTimeOffset.UtcNow.AddMinutes(10)));
            else
                store.Save(oldInsecureSource, "fixture-manual-token");
            var previous = new BridgeSettings { HermesServiceUrl = oldInsecureSource, HermesAllowAnonymous = true };
            await using var runtime = new BridgeRuntime(previous, new byte[32], true, store);
            try
            {
                await runtime.GetHermesAccessTokenAsync(oldInsecureSource, null, runtime.HermesSourceRevision, CancellationToken.None);
                throw new Exception("Saved nonloopback HTTP credentials were returned or silently downgraded to anonymous");
            }
            catch (HermesAuthenticationException e)
            {
                Check(!e.RequiresLogin && e.Message == HermesCredentialTransport.HttpsRequiredMessage && runtime.HermesUsageStatus == e.Message,
                    "Saved insecure source must explain how to switch to HTTPS or remove its credentials");
            }
            Check(runtime.HasHermesAccessToken && runtime.LogoutHermes(out _) && !File.Exists(path),
                "A transport refusal must not erase the saved credential or prevent explicit removal");
        }
        Console.WriteLine("PASS saved nonloopback HTTP manual and account credentials: blocked without anonymous fallback; removable");
        await using (var runtime = new BridgeRuntime(new BridgeSettings(), new byte[32], true, store))
        {
            var pending = runtime.LoginHermesAsync(endpoint + "/pending", null, "fixture-user", "fixture-password");
            await entered.Task.WaitAsync(TimeSpan.FromSeconds(5));
            Check(runtime.LogoutHermes(out _), "Logout failed");
            release.TrySetResult();
            Check(!(await pending).Ok && runtime.HermesSignedInUsername is null && !File.Exists(path), "Late login resurrected logged-out session");
        }
        async Task<(BridgeRuntime Runtime, string Url)> Expiring(string mode)
        {
            var url = endpoint + "/" + mode + "/";
            store.SaveSession(url, null, new("fixture-access", "fixture-refresh", "basic", "fixture-user", DateTimeOffset.UtcNow.AddSeconds(30)));
            return (await Task.FromResult(new BridgeRuntime(new BridgeSettings { HermesServiceUrl = url }, new byte[32], true, store)), url);
        }
        var expired = await Expiring("refreshbad");
        await using (var runtime = expired.Runtime)
        {
            for (var i = 0; i < 2; i++)
            {
                try { await runtime.GetHermesAccessTokenAsync(expired.Url, null, runtime.HermesSourceRevision, CancellationToken.None); throw new Exception("Expired refresh accepted"); }
                catch (HermesAuthenticationException e) { Check(e.RequiresLogin, "Refresh401 must require login"); }
            }
            Check(runtime.HermesSignedInUsername is null && !runtime.HasHermesAccessToken && runtime.NativeHermesStatus.Contains("重新登录"), "Refresh401 not reflected in runtime");
        }
        var late = await Expiring("refreshpending");
        await using (var runtime = late.Runtime)
        {
            var refresh = runtime.GetHermesAccessTokenAsync(late.Url, null, runtime.HermesSourceRevision, CancellationToken.None);
            await refreshEntered.Task.WaitAsync(TimeSpan.FromSeconds(5));
            Check(runtime.TrySetHermesSource(endpoint + "/changed", null, "", false, out _, allowAnonymous: true), "Source change rejected");
            refreshRelease.TrySetResult();
            try { await refresh; throw new Exception("Late refresh escaped source fence"); } catch (HermesAuthenticationException) { }
            Check(!File.Exists(path) && runtime.HermesSignedInUsername is null, "Late refresh persisted wrong-source session");
        }
        var failure = await Expiring("savefail");
        await using (var runtime = failure.Runtime)
        {
            failSave = true;
            try { await runtime.GetHermesAccessTokenAsync(failure.Url, null, runtime.HermesSourceRevision, CancellationToken.None); throw new Exception("Undurable rotation returned as success"); }
            catch (HermesAuthenticationException e) { Check(e.RequiresLogin, "Rotation save failure must require login"); }
            finally { failSave = false; }
            Check(runtime.HermesSignedInUsername is null && !runtime.HasHermesAccessToken, "Undurable rotation remains signed in");
        }
        var rejected = await Expiring("usage401");
        await using (var runtime = rejected.Runtime)
        using (var ct = new CancellationTokenSource(TimeSpan.FromSeconds(8)))
        {
            await runtime.StartAsync(ct.Token, startWebListener: false);
            while (!runtime.NativeHermesStatus.Contains("失败") && runtime.HermesSignedInUsername is not null) await Task.Delay(50, ct.Token);
            Check(runtime.HermesSignedInUsername is null && !runtime.HasHermesAccessToken && runtime.NativeHermesStatus.Contains("重新登录"), "Analytics401 must invalidate account and prompt relogin");
            ct.Cancel();
        }
        File.Delete(path);
        Console.WriteLine("PASS runtime auth fences: pending login/logout, source-changed refresh, refresh401, durable-rotation failure and analytics401");
    }

    private static void Cookies()
    {
        foreach (var prefix in new[] { "", "__Host-", "__Secure-" })
        foreach (var suffix in new[] { "", "_0123456789abcdef" })
        {
            var value = NativeHermesAuthClient.ExtractSessionCookies(new[] { $"{prefix}hermes_session_at{suffix}=\"fixture-access\"; HttpOnly; Path=/", $"{prefix}hermes_session_rt{suffix}=fixture-refresh; HttpOnly" });
            Check(value == ("fixture-access", "fixture-refresh"), "Supported exact cookie variant rejected");
        }
        foreach (var values in new[] {
            new[] { "prefix_hermes_session_at=fixture-access" },
            new[] { "hermes_session_at_attacker=fixture-access" },
            new[] { "hermes_session_at=fixture-access", "hermes_session_at=duplicate" },
            new[] { "hermes_session_at=fixture-access", "__Host-hermes_session_rt=fixture-refresh" },
            new[] { "hermes_session_at=fixture-access", "hermes_session_rt_0123456789abcdef=fixture-refresh" },
            new[] { "hermes_session_at=" }, new[] { "hermes_session_at=bad token" } })
        {
            try { NativeHermesAuthClient.ExtractSessionCookies(values); throw new Exception("Unsafe cookies accepted"); }
            catch (Exception e) when (e is HermesAuthenticationException or ArgumentException) { }
        }
        Console.WriteLine("PASS session cookie exact allowlist: bare/Host/Secure + 16hex gateway suffix, quotes, duplicates/mixed variants/unknown suffix/empty/invalid rejection");
    }
}
