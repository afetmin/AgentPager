using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text.Json;
using AgentPager.Core;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Logging;

internal static class NativeHermesSafetyTests
{
    public static async Task Run()
    {
        foreach (var invalid in new[] { "ftp://localhost:123", "http://user:password@localhost", "http://localhost/?", "http://localhost/#", "http://localhost/?token=secret", "http://localhost/#secret", "relative/path", "http://localhost\\evil" })
        {
            try { NativeHermesUsageClient.ValidateBaseUrl(invalid); throw new Exception("Invalid native URL accepted"); }
            catch (ArgumentException) { }
        }
        var builder = WebApplication.CreateSlimBuilder();
        builder.Logging.ClearProviders();
        builder.WebHost.UseUrls("http://127.0.0.1:0");
        await using var app = builder.Build();
        var leaks = 0;
        app.MapGet("/leak", () => { leaks++; return "must not follow"; });
        app.MapGet("/{mode}/api/analytics/{kind}", async context =>
        {
            var mode = context.Request.RouteValues["mode"]!.ToString();
            var kind = context.Request.RouteValues["kind"]!.ToString();
            var days = int.Parse(context.Request.Query["days"]!);
            if (context.Request.Headers.Cookie.Count != 0) throw new Exception("Cookies must never be sent");
            if (mode == "redirect") { context.Response.StatusCode = 302; context.Response.Headers.Location = "/leak"; context.Response.Headers.SetCookie = "session=private"; return; }
            if (mode == "unauthorized") { context.Response.StatusCode = 401; return; }
            if (mode == "missing" && kind == "models" && days == 7) { context.Response.StatusCode = 503; return; }
            if (mode == "oversized") { await context.Response.WriteAsync(new string(' ', HermesUsageSnapshot.MaximumBytes + 1)); return; }
            if (mode == "slow") { await Task.Delay(TimeSpan.FromSeconds(10), context.RequestAborted); return; }
            context.Response.ContentType = "application/json";
            var input = mode == "negative" ? -1 : 100;
            await context.Response.WriteAsync(kind == "usage"
                ? JsonSerializer.Serialize(new { period_days = 90, daily = Array.Empty<object>() })
                : JsonSerializer.Serialize(new { period_days = mode == "mismatch" ? 42 : days, models = new[] { new { model = "unknown-price-model", provider = "provider", input_tokens = input, output_tokens = 10, estimated_cost = 0 } } }));
        });
        await app.StartAsync();
        using var reader = new NativeHermesUsageClient();
        var endpoint = app.Urls.Single();
        var unknown = await reader.ReadAsync(endpoint + "/unknown", null, "", CancellationToken.None);
        if (unknown.IsPartial || unknown.Periods!.Any(p => p.TotalTokens != 110 || p.EstimatedCostUSD is not null || !p.IsPartial))
            throw new Exception("Positive usage with unknown/zero source price must stay null, not free; snapshot transport remains complete");
        var localhost = new UriBuilder(endpoint) { Host = "localhost", Path = "unknown" }.Uri.AbsoluteUri;
        if ((await reader.ReadAsync(localhost, null, "fixture-loopback-token", CancellationToken.None)).IsPartial)
            throw new Exception("Pinned localhost HTTP must still support bearer analytics");
        var partial = await reader.ReadAsync(endpoint + "/missing", null, "", CancellationToken.None);
        if (!partial.IsPartial || partial.Periods!.Count != 2 || partial.Periods.Any(p => p.Days == 7))
            throw new Exception("Missing 7-day source must not synthesize or substitute other period");
        foreach (var mode in new[] { "redirect", "unauthorized", "oversized" })
        {
            try { await reader.ReadAsync(endpoint + "/" + mode, null, "fixture-secret", CancellationToken.None); throw new Exception("Unsafe/failed HTTP response accepted"); }
            catch (IOException e) { if (e.Message.Contains("fixture-secret")) throw new Exception("Secret leaked in error"); }
        }
        foreach (var mode in new[] { "negative", "mismatch" })
        {
            var rejected = await reader.ReadAsync(endpoint + "/" + mode, null, "", CancellationToken.None);
            if (!rejected.IsPartial || rejected.Periods!.Count != 0) throw new Exception("Invalid model data must not publish a range");
        }
        if (leaks != 0) throw new Exception("Native token followed an HTTP redirect");
        using var cancel = new CancellationTokenSource(TimeSpan.FromMilliseconds(100));
        var clock = System.Diagnostics.Stopwatch.StartNew();
        try { await reader.ReadAsync(endpoint + "/slow", null, "", cancel.Token); throw new Exception("Reader ignored cancellation"); }
        catch (OperationCanceledException) { }
        if (clock.Elapsed > TimeSpan.FromSeconds(3)) throw new Exception("Native cancellation exceeded bound");
        Console.WriteLine("PASS native HTTP safety: invalid URLs, unknown zero price, partial ranges, redirect refusal, 401, body bound, invalid counters/ranges, cancellation");
        await CredentialTransport();
    }

    private static async Task CredentialTransport()
    {
        foreach (var url in new[] { "https://nas.example/base/", "http://localhost:8080/base/", "http://localhost./", "http://127.0.0.1/", "http://[::1]/", "http://[::ffff:127.0.0.1]/" })
            if (!HermesCredentialTransport.AllowsCredentials(NativeHermesUsageClient.ValidateBaseUrl(url)))
                throw new Exception("HTTPS or loopback unexpectedly refused");
        foreach (var url in new[] { "http://nas.example/", "http://localhost.example/", "http://192.168.0.10/", "http://[::ffff:192.168.0.10]/", "http://0.0.0.0/", "http://[::]/" })
            if (HermesCredentialTransport.AllowsCredentials(NativeHermesUsageClient.ValidateBaseUrl(url)))
                throw new Exception("Nonloopback HTTP accepted credentials");
        var address = NetworkInterface.GetAllNetworkInterfaces().SelectMany(n => n.GetIPProperties().UnicastAddresses)
            .Select(a => a.Address).FirstOrDefault(a => a.AddressFamily == AddressFamily.InterNetwork && !IPAddress.IsLoopback(a));
        var builder = WebApplication.CreateSlimBuilder();
        builder.Logging.ClearProviders();
        builder.WebHost.UseUrls(address is null ? "http://127.0.0.1:0" : $"http://{address}:0");
        await using var app = builder.Build();
        var requests = 0;
        var authorized = 0;
        app.Use(async (context, next) =>
        {
            Interlocked.Increment(ref requests);
            if (context.Request.Headers.ContainsKey("Authorization") || context.Request.Headers.ContainsKey("Cookie"))
                Interlocked.Increment(ref authorized);
            await next();
        });
        app.MapGet("/base/api/status", () => Results.Json(new { auth_providers = new[] { "basic" }, auth_flows = new[] { "native_pkce" } }));
        app.MapPost("/base/auth/native/refresh", () => Results.Unauthorized());
        app.MapGet("/base/api/analytics/{kind}", (string kind, int days) => kind == "usage"
            ? Results.Json(new { period_days = days, daily = Array.Empty<object>() })
            : Results.Json(new { period_days = days, models = Array.Empty<object>() }));
        await app.StartAsync();
        var source = app.Urls.Single() + "/base/";
        var insecure = address is null ? "http://192.0.2.15/base/" : source;
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        using var auth = new NativeHermesAuthClient();
        using var usage = new NativeHermesUsageClient();
        var unexpired = new HermesAccountSession("fixture-access", "fixture-refresh", "basic", "fixture-user", DateTimeOffset.UtcNow.AddMinutes(5));
        await Reject(() => auth.LoginAsync(insecure, "fixture-user", "fixture-password", deadline.Token), "password login");
        await Reject(() => auth.RefreshAsync(insecure, unexpired, deadline.Token), "refresh");
        await Reject(() => usage.ReadAsync(insecure, null, "fixture-access", deadline.Token), "bearer analytics");
        if (Volatile.Read(ref requests) != 0) throw new Exception("Credential rejection must precede even unauthenticated discovery");

        var snapshot = await usage.ReadAsync(source, null, "", deadline.Token);
        if (snapshot.IsPartial || Volatile.Read(ref requests) != 4 || Volatile.Read(ref authorized) != 0)
            throw new Exception("Anonymous HTTP must still read analytics without a bearer or cookie");
        Console.WriteLine("PASS credential transport: password, refresh and bearer blocked before discovery/send; anonymous HTTP preserved");

        static async Task Reject(Func<Task> operation, string flow)
        {
            try { await operation(); }
            catch (HermesAuthenticationException e) when (e.Message.Contains("HTTPS") && !e.Message.Contains("fixture-")) { return; }
            throw new Exception($"Expected actionable HTTPS refusal for {flow}");
        }
    }
}
