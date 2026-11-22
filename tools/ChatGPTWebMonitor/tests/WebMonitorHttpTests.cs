using System.Net;
using System.Text;
using System.Text.Json;
using AgentPager.Core;

internal static class WebMonitorHttpTests
{
    public static async Task Run()
    {
        var type = typeof(ChatGPTWebStatusTracker).Assembly.GetType("AgentPager.Bridge.ChatGPTWebMonitorHost");
        Check(type is not null, "web monitor host is integrated and testable without WPF/another EXE");
        await RunHost();
    }

    private static async Task RunHost()
    {
        var clock = DateTimeOffset.UtcNow;
        var catalog = new TaskCatalog();
        catalog.AcceptHermesStatus(AgentLifecycle.Running, clock);
        var options = new JsonSerializerOptions { PropertyNameCaseInsensitive = true };
        options.Converters.Add(new System.Text.Json.Serialization.JsonStringEnumConverter());
        await using var host = new AgentPager.Bridge.ChatGPTWebMonitorHost(payload => {
            catalog.Accept(JsonSerializer.Deserialize<CodexHookPayload>(JsonSerializer.Serialize(payload), options)!, clock);
            return true;
        }, true, 0, () => clock);
        var stateChanges = 0;
        host.StateChanged += () => stateChanges++;
        await host.StartAsync(CancellationToken.None);
        var initialChanges = stateChanges;
        host.Tick();
        Check(stateChanges == initialChanges, "unchanged timer ticks do not refresh/reset WPF controls");
        using var client = new HttpClient { BaseAddress = new Uri(host.Address!) };
        async Task<(HttpStatusCode Code, JsonElement State)> Send(string method, string path, string? body = null,
            string origin = "chrome-extension://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", string? token = AgentPager.Bridge.ChatGPTWebMonitorHost.Token,
            string? hostHeader = null)
        {
            using var request = new HttpRequestMessage(new HttpMethod(method), path);
            request.Headers.Add("Origin", origin);
            if (token is not null) request.Headers.Add("X-AgentPager-Token", token);
            if (hostHeader is not null) request.Headers.Host = hostHeader;
            if (body is not null) request.Content = new StringContent(body, Encoding.UTF8, "application/json");

            using var response = await client.SendAsync(request);
            var text = await response.Content.ReadAsStringAsync();
            return (response.StatusCode, text.Length == 0 ? default : JsonSerializer.Deserialize<JsonElement>(text));
        }
        var state = await Send("GET", "/status");
        Check(state.Code == HttpStatusCode.OK && state.State.GetProperty("status").GetString() == "waiting-browser", "HTTP diagnostic initially waits for browser");
        Check((await Send("GET", "/status", token: null)).Code == HttpStatusCode.Forbidden, "HTTP diagnostic requires capability");
        Check((await Send("POST", "/state", "{}", origin: "https://chatgpt.com")).Code == HttpStatusCode.Forbidden, "webpage origin rejected");
        Check((await Send("POST", "/state", "{}", origin: "null")).Code == HttpStatusCode.Forbidden, "opaque origin rejected");
        Check((await Send("GET", "/status", hostHeader: "attacker.invalid")).Code == HttpStatusCode.Forbidden, "DNS rebinding Host rejected");
        const string firefoxOrigin = "moz-extension://11111111-2222-4333-8444-555555555555";
        Check((await Send("OPTIONS", "/state", origin: firefoxOrigin, token: null)).Code == HttpStatusCode.NoContent &&
              (await Send("GET", "/status", origin: firefoxOrigin)).Code == HttpStatusCode.OK, "Firefox UUID Origin works on loopback");
        Check((await Send("GET", "/status", origin: firefoxOrigin + ".invalid")).Code == HttpStatusCode.Forbidden &&
              (await Send("GET", "/status", origin: firefoxOrigin + "/")).Code == HttpStatusCode.Forbidden &&
              (await Send("GET", "/status", origin: firefoxOrigin, token: null)).Code == HttpStatusCode.Forbidden,
              "Firefox origin has no suffix/path and still requires capability");
        Check((await Send("OPTIONS", "/state", token: null)).Code == HttpStatusCode.NoContent, "extension CORS preflight accepted");
        state = await Send("POST", "/state", "{\"type\":\"browser.heartbeat\",\"tabCount\":2}");
        Check(state.Code == HttpStatusCode.OK && state.State.GetProperty("tabCount").GetInt32() == 2 &&
              state.State.GetProperty("status").GetString() == "connected" && catalog.Projection().Tasks.Count == 1,
              "idle browser heartbeat is visible without creating generation tasks");
        state = await Send("POST", "/state", "{\"type\":\"browser.heartbeat\",\"tabCount\":2,\"sidebarRows\":12,\"spinningRows\":1}");
        Check(state.Code == HttpStatusCode.OK && state.State.GetProperty("sidebarRows").GetInt32() == 12 &&
              state.State.GetProperty("spinningRows").GetInt32() == 1, "browser row diagnostics are safely exposed");
        Check((await Send("POST", "/state", "{\"type\":\"browser.heartbeat\",\"tabCount\":2,\"sidebarRows\":251}")).Code == HttpStatusCode.BadRequest,
              "browser diagnostic rows are bounded");
        Check((await Send("POST", "/state", "{\"type\":\"browser.heartbeat\",\"tabCount\":-1}")).Code == HttpStatusCode.BadRequest, "invalid tab count rejected");
        Check((await Send("POST", "/state", "{\"type\":\"browser.heartbeat\",\"tabCount\":1,\"prompt\":\"private\"}")).Code == HttpStatusCode.BadRequest, "chat body fields rejected");
        var hash = new string('e', 64);
        var generation = JsonSerializer.Serialize(new { action = "start", conversationHash = hash, requestId = "dom-one", mode = "Chat", title = "Visible conversation",
            observationId = "document-one:7", observedAt = clock.ToUnixTimeMilliseconds(), signal = "sidebar-spinner" });
        state = await Send("POST", "/state", generation);
        Check(state.Code == HttpStatusCode.OK && state.State.GetProperty("activeSessionCount").GetInt32() == 1 &&
              state.State.GetProperty("lastDetectionAction").GetString() == "start" &&
              catalog.Projection().Tasks.Single(t => t.Id.EndsWith(hash)).Lifecycle == AgentLifecycle.Running,
              "HTTP start enters real catalog and diagnostic detection");
        // v0.2 sent a legacy, always-empty prompt key on each generation event.
        var legacy = generation[..^1] + ",\"prompt\":\"\"}";
        Check((await Send("POST", "/state", legacy)).Code == HttpStatusCode.OK,
              "previous extension's empty legacy prompt field does not drop its entire generation event");
        Check((await Send("POST", "/state", generation[..^1] + ",\"prompt\":\"fixture-body-must-not-cross\"}")).Code == HttpStatusCode.BadRequest,
              "legacy compatibility never accepts nonempty chat text");
        clock = clock.AddSeconds(101);
        host.Tick();
        state = await Send("GET", "/status");
        Check(state.State.GetProperty("status").GetString() == "browser-offline" &&
              catalog.Projection().Tasks.Single(t => t.Id.EndsWith(hash)).Lifecycle == AgentLifecycle.Offline,
              "browser loss expires generation to Offline and visible disconnected diagnostic");
        await Send("POST", "/state", generation);
        host.SetEnabled(false);
        state = await Send("GET", "/status");
        Check(state.State.GetProperty("status").GetString() == "disabled" && state.State.GetProperty("activeSessionCount").GetInt32() == 0 &&
              catalog.Projection().Tasks.Single(t => t.Id.EndsWith(hash)).Lifecycle == AgentLifecycle.Offline &&
              catalog.Projection().Tasks.Single(t => t.Source == AgentSource.HermesDesktop).Lifecycle == AgentLifecycle.Running,
              "disable clears only web Running state and leaves Hermes untouched");
        Check(state.State.GetProperty("lastBrowserHeartbeatAt").ValueKind == JsonValueKind.String &&
              state.State.GetProperty("lastDetectionAt").ValueKind == JsonValueKind.String,
              "disable retains last heartbeat and detection timestamps for diagnosis");
        state = await Send("POST", "/state", generation);
        Check(state.Code == HttpStatusCode.OK && !state.State.GetProperty("enabled").GetBoolean() &&
              catalog.Projection().Tasks.Single(t => t.Id.EndsWith(hash)).Lifecycle == AgentLifecycle.Offline,
              "disabled HTTP observation cannot reactivate a web task");
        host.SetEnabled(true);
        Check((await Send("GET", "/status")).State.GetProperty("status").GetString() == "waiting-browser", "reenable waits for fresh browser");
        Check((await Send("POST", "/state", "[]")).Code == HttpStatusCode.BadRequest, "non-object JSON rejected");
        Check((await Send("POST", "/state", "{")).Code == HttpStatusCode.BadRequest, "malformed JSON rejected");
        Check((await Send("POST", "/state", new string('x', 16385))).Code == HttpStatusCode.RequestEntityTooLarge, "oversize body rejected");
        Check((await Send("POST", "/state", generation)).Code == HttpStatusCode.OK,
              "valid request after rejected oversize body succeeds without a pooled-connection abort");
        clock = clock.AddSeconds(80);
        await Send("POST", "/state", "{\"type\":\"browser.heartbeat\",\"tabCount\":2}");
        clock = clock.AddSeconds(21);
        host.Tick();
        state = await Send("GET", "/status");
        Check(state.State.GetProperty("status").GetString() == "connected" &&
              catalog.Projection().Tasks.Single(t => t.Id.EndsWith(hash)).Lifecycle == AgentLifecycle.Offline,
              "idle browser diagnostic cannot keep an unobserved generation Running");
        await using var conflict = new AgentPager.Bridge.ChatGPTWebMonitorHost(_ => true, port: new Uri(host.Address!).Port);
        var failed = false;
        try { await conflict.StartAsync(CancellationToken.None); }
        catch (IOException) { failed = true; }
        Check(failed && conflict.State.Status == "listener-error" && host.State.Listening,
              "port conflict is visible and does not disturb the existing listener");
        Console.WriteLine("ALL INTEGRATED HTTP WEB MONITOR TESTS PASSED");
    }

    private static void Check(bool value, string message)
    {
        if (!value) throw new Exception(message);
        Console.WriteLine("PASS " + message);
    }
}
