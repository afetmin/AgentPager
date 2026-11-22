using System.Net;
using System.Text;
using System.Text.Json;
using AgentPager.Bridge;
using AgentPager.Core;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.Extensions.Logging;

SourceTitleTests.Run();
HermesPluginUpgradeTests.Run();
HermesHistoryTests.Run();
var dir = Directory.CreateTempSubdirectory("agentpager-hermes-");
try
{
    var file = Path.Combine(dir.FullName, "status.json");
    var reader = new HermesDesktopStatus(file);
    var catalog = new TaskCatalog();
    var now = DateTimeOffset.FromUnixTimeMilliseconds(1_800_000_000_000);
    void Write(string state, DateTimeOffset at, int version = 1) => File.WriteAllText(file,
        JsonSerializer.Serialize(new { version, state, updatedAt = at.ToUnixTimeMilliseconds() }));
    void Check(bool condition, string description)
    {
        if (!condition) throw new InvalidOperationException(description);
    }

    Check(reader.Read(now) is null, "Missing status must not create a task.");
    const string key = "1000000000000000000000000000000000000000000000000000000000000000";
    byte[] Packet(string token, string state, DateTimeOffset at) => JsonSerializer.SerializeToUtf8Bytes(
        new { token, version = 1, state, updatedAt = at.ToUnixTimeMilliseconds() });
    Check(HermesHeartbeat.Parse(Packet("wrong", "running", now), now, key) is null,
        "Reject an unauthenticated loopback heartbeat.");
    Check(HermesHeartbeat.Parse(Packet(key, "running", now.AddMinutes(-2)), now, key) is null,
        "Reject a replayed loopback heartbeat.");
    var heartbeat = HermesHeartbeat.Parse(Packet(key, "running", now), now, key);
    Check(heartbeat is { Lifecycle: AgentLifecycle.Running }, "Accept an authenticated loopback heartbeat.");
    var fromLegacyPlugin = new HermesDesktopStatus(file);
    fromLegacyPlugin.Accept(heartbeat!, "本机连接");
    Check(fromLegacyPlugin.Read(now) == AgentLifecycle.Running && fromLegacyPlugin.Transport == "本机连接",
        "An older Hermes Desktop without a local file must still appear as working.");
    Check(fromLegacyPlugin.Read(now.AddSeconds(90)) == AgentLifecycle.Offline,
        "A silent legacy plugin must go offline after its heartbeat times out.");
    Write("running", now.AddMinutes(1));
    Check(reader.Read(now) is null, "Reject future timestamps.");
    Write("idle", now, version: 2);
    Check(reader.Read(now) is null, "Reject unsupported schema versions.");
    Write("running", now);
    Check(reader.Read(now) == AgentLifecycle.Running, "Read running status.");
    Check(catalog.AcceptHermesStatus(AgentLifecycle.Running, now), "Publish the first status.");
    var task = catalog.Projection().Tasks.Single();
    Check(task.Capabilities.Count == 0 && task.UserPrompt is null, "Status must be read-only and private.");
    Check(JsonSerializer.Serialize(task, WireJson.Options).Contains("\"source\":\"hermesDesktop\""),
        "Phone receives the Hermes source id.");
    Check(!catalog.AcceptHermesStatus(AgentLifecycle.Running, now.AddSeconds(5)), "Do not rebroadcast heartbeat.");
    File.WriteAllText(file, new string('x', 1_025));
    Check(reader.Read(now.AddSeconds(89)) == AgentLifecycle.Running, "Ignore malformed temporary writes.");
    Check(reader.Read(now.AddSeconds(90)) == AgentLifecycle.Offline, "Running expires when Hermes closes.");
    Check(catalog.AcceptHermesStatus(AgentLifecycle.Offline, now.AddSeconds(90)), "Publish offline transition.");
    Write("idle", now.AddSeconds(91));
    Check(reader.Read(now.AddSeconds(91)) == AgentLifecycle.Idle, "Fresh idle heartbeat recovers.");
    Check(catalog.AcceptHermesStatus(AgentLifecycle.Idle, now.AddSeconds(91)), "Publish idle transition.");
    Check(catalog.Projection().Tasks.Single().Id == task.Id, "Status transitions use a single stable task.");
    var persistence = new TaskSnapshotPersistence(Path.Combine(dir.FullName, "tasks.json"));
    persistence.Save(catalog.Projection().Tasks);
    Check(persistence.Load().Count == 0, "Do not persist transient Hermes status.");

    // SDK-shaped v2 metadata must become independent read-only cards without changing the Android wire model.
    var conversationsPacket = JsonSerializer.SerializeToUtf8Bytes(new {
        version = 2, state = "running", updatedAt = now.ToUnixTimeMilliseconds(), token = key,
        sessions = new[] {
            new { id = new string('a', 64), title = "修复支付 API", state = "running", updatedAt = now.ToUnixTimeMilliseconds() },
            new { id = new string('b', 64), title = "整理文档", state = "idle", updatedAt = now.ToUnixTimeMilliseconds() },
        }
    });
    var conversations = HermesHeartbeat.Parse(conversationsPacket, now, key);
    Check(conversations is not null, "Accept bounded per-conversation v2 metadata.");
    Check(catalog.AcceptHermesStatus(conversations!, now), "Replace the aggregate card with a conversation snapshot.");
    var terminalPacket = Encoding.UTF8.GetString(conversationsPacket).Replace("\"state\":\"idle\"", "\"state\":\"succeeded\"");
    var terminalHeartbeat = HermesHeartbeat.Parse(Encoding.UTF8.GetBytes(terminalPacket), now, key);
    Check(terminalHeartbeat is not null, "Explicit per-conversation success is supported.");
    var terminalCatalog = new TaskCatalog();
    terminalCatalog.AcceptHermesStatus(terminalHeartbeat!, now.AddSeconds(1));
    var completedCard = terminalCatalog.Projection().Tasks.Single(card => card.Title == "Hermes · 整理文档");
    Check(completedCard.Lifecycle == AgentLifecycle.Succeeded && completedCard.CompletedAt is not null,
        "Succeeded Hermes cards have completion time so Android can render without crashing.");
    terminalCatalog.AcceptHermesStatus(conversations!, now.AddSeconds(2));
    Check(terminalCatalog.Projection().Tasks.All(card => card.CompletedAt is null), "Nonterminal observation clears terminal time.");

    var cards = catalog.Projection().Tasks;
    Check(cards.Count == 2 && cards.All(card => card.Id.StartsWith("hermes-desktop:session:")), "One stable card per conversation; remove aggregate.");
    Check(cards.Single(card => card.Title == "Hermes · 修复支付 API").Lifecycle == AgentLifecycle.Running &&
        cards.Single(card => card.Title == "Hermes · 整理文档").Lifecycle == AgentLifecycle.Idle, "Activity is independent per conversation.");
    Check(cards.All(card => card.UserPrompt is null && card.LatestStep is null && card.Capabilities.Count == 0), "Only bounded title/id/status reach Android.");
    Check(!catalog.AcceptHermesStatus(conversations! with { UpdatedAt = now.AddSeconds(5) }, now.AddSeconds(5)), "Heartbeat alone does not reorder cards or increment revision.");
    var renamed = conversations! with { Conversations = conversations!.Conversations!.Select(card => card.Id[0] == 'a' ? card with { Title = "支付 API 回归测试" } : card).ToArray() };
    Check(catalog.AcceptHermesStatus(renamed, now.AddSeconds(6)), "Real title changes update the existing card.");
    Check(catalog.Projection().Tasks.Single(card => card.Title == "Hermes · 支付 API 回归测试").UpdatedAt == now, "A rename is metadata, not activity.");
    var conversationReader = new HermesDesktopStatus(Path.Combine(dir.FullName, "no-file"));
    conversationReader.Accept(conversations!, "本机连接");
    Check(catalog.AcceptHermesStatus(conversationReader.Snapshot(now.AddSeconds(90))!, now.AddSeconds(90)), "Expire each conversation when the producer disappears.");
    Check(catalog.Projection().Tasks.All(card => card.Lifecycle == AgentLifecycle.Offline), "No conversation stays running after timeout.");
    Check(catalog.AcceptHermesStatus(conversations! with { Conversations = Array.Empty<HermesConversation>() }, now.AddSeconds(91)), "Empty connected roster clears cards.");
    Check(catalog.Projection().Tasks.Count == 0, "Connected idle with no conversations must not invent an aggregate card.");
    catalog.AcceptHermesStatus(conversations!, now);
    persistence.Save(catalog.Projection().Tasks);
    Check(persistence.Load().Count == 0, "Per-conversation metadata remains transient, just like the legacy aggregate.");
    Check(catalog.AcceptHermesStatus(new HermesHeartbeat(AgentLifecycle.Idle, now.AddSeconds(92)), now.AddSeconds(92)), "Legacy producer recovery is supported.");
    Check(catalog.Projection().Tasks.Count == 1 && catalog.Projection().Tasks[0].Id == "hermes-desktop:status", "Legacy fallback must replace, not accompany, v2 cards.");
    var monoReader = new HermesDesktopStatus(Path.Combine(dir.FullName, "never-exists"));
    monoReader.Accept(conversations!, "本机连接");
    var sameMillisecond = renamed with { Conversations = renamed.Conversations!.Select(card => card with { Lifecycle = AgentLifecycle.Idle }).ToArray() };
    monoReader.Accept(sameMillisecond, "本机连接");
    Check(monoReader.Snapshot(now)!.Conversations!.All(card => card.Lifecycle == AgentLifecycle.Idle), "Distinct states in the same millisecond must not be lost.");
    monoReader.Accept(new HermesHeartbeat(AgentLifecycle.Running, now.AddSeconds(1)), "状态文件");
    Check(monoReader.Snapshot(now.AddSeconds(1))!.Conversations is not null, "An old aggregate file cannot downgrade a healthy per-conversation producer.");

    byte[] Variant(object rows, object? timestamp = null, object? schema = null) => JsonSerializer.SerializeToUtf8Bytes(new {
        version = schema ?? 2, state = "running", updatedAt = timestamp ?? now.ToUnixTimeMilliseconds(), token = key, sessions = rows
    });
    var goodRows = new[] { new { id = new string('c', 64), title = "Valid", state = "idle", updatedAt = now.ToUnixTimeMilliseconds() } };
    Check(HermesHeartbeat.Parse(Variant(goodRows), now, key) is not null, "Accept a minimal v2 conversation.");
    Check(HermesHeartbeat.Parse(Variant(goodRows, schema: "2"), now, key) is null, "Reject nonnumeric schema instead of throwing.");
    Check(HermesHeartbeat.Parse(Variant(goodRows, timestamp: long.MaxValue), now, key) is null, "Reject overflowing/future timestamps.");
    Check(HermesHeartbeat.Parse(Variant(Enumerable.Repeat(goodRows[0], 21)), now, key) is null, "Reject more than 20 cards.");
    Check(HermesHeartbeat.Parse(Variant(Enumerable.Repeat(goodRows[0], 2)), now, key) is null, "Reject duplicate conversation IDs.");
    Check(HermesHeartbeat.Parse(Variant(new[] { new { id = "not-a-hash", title = "Valid", state = "idle", updatedAt = now.ToUnixTimeMilliseconds() } }), now, key) is null, "Reject malformed IDs.");
    Check(HermesHeartbeat.Parse(Variant(new[] { new { id = new string('c', 64), title = new string('文', 161), state = "idle", updatedAt = now.ToUnixTimeMilliseconds() } }), now, key) is null, "Reject oversized titles.");
    Check(HermesHeartbeat.Parse(Variant(new[] { new { id = new string('c', 64), title = "Valid", state = "idle", updatedAt = now.ToUnixTimeMilliseconds(), preview = "must not be accepted" } }), now, key) is null, "Reject accidental chat-body fields.");
    Check(HermesHeartbeat.Parse(new byte[HermesHeartbeat.MaximumBytes + 1], now, key) is null, "Bound total payload bytes.");

    var modelPacket = JsonSerializer.SerializeToUtf8Bytes(new {
        version = 2, state = "running", updatedAt = now.ToUnixTimeMilliseconds(),
        sessions = new[] { new { id = new string('d', 64), title = "Model usage", state = "running", updatedAt = now.ToUnixTimeMilliseconds(),
            modelUsage = new { model = "model-a", provider = "provider-a", inputTokens = 100, outputTokens = 20, totalTokens = 120,
                estimatedCostUSD = 0.25, costSource = "current_model_pricing",
                quota = new { label = "Today", usedPercentage = 12.5, resetsAt = now.AddHours(1).ToUnixTimeMilliseconds(), source = "session_plan_gauge" } } } }
    });
    var modelHeartbeat = HermesHeartbeat.Parse(modelPacket, now);
    Check(modelHeartbeat is not null, "Accept optional bounded native SDK usage without breaking v2.");
    var modelCatalog = new TaskCatalog();
    modelCatalog.AcceptHermesStatus(modelHeartbeat!, now);
    var modelWire = JsonSerializer.Serialize(modelCatalog.Projection().Tasks.Single(), WireJson.Options);
    using (var modelDocument = JsonDocument.Parse(modelWire))
    {
        Check(modelDocument.RootElement.GetProperty("modelUsage").GetProperty("estimatedCostUSD").GetDouble() == 0.25,
            "Forward estimate (not an actual bill) to the phone.");
        Check(modelDocument.RootElement.GetProperty("tokenUsage").GetProperty("total").GetInt32() == 120,
            "Existing token UI still receives native counters.");
    }
    Check(!modelCatalog.AcceptHermesStatus(modelHeartbeat!, now.AddSeconds(5)), "Unchanged usage is not activity.");
    var variantNode = System.Text.Json.Nodes.JsonNode.Parse(modelPacket)!;
    variantNode["sessions"]![0]!["modelUsage"]!["inputTokens"] = -1;
    Check(HermesHeartbeat.Parse(Encoding.UTF8.GetBytes(variantNode.ToJsonString()), now) is null, "Reject negative usage counters.");
    variantNode["sessions"]![0]!["modelUsage"]!["inputTokens"] = 100;
    variantNode["sessions"]![0]!["modelUsage"]!["quota"]!["usedPercentage"] = 101;
    Check(HermesHeartbeat.Parse(Encoding.UTF8.GetBytes(variantNode.ToJsonString()), now) is null, "Reject impossible subscription percentages.");
    variantNode["sessions"]![0]!["modelUsage"]!["quota"]!["usedPercentage"] = 12.5;
    variantNode["sessions"]![0]!["modelUsage"]!["quota"]!["preview"] = "must not pass";
    Check(HermesHeartbeat.Parse(Encoding.UTF8.GetBytes(variantNode.ToJsonString()), now) is null, "Reject accidental private nested metadata.");
    var rootNode = System.Text.Json.Nodes.JsonNode.Parse(modelPacket)!;
    rootNode["sessions"]![0]!.AsObject().Remove("modelUsage");
    var noUsage = HermesHeartbeat.Parse(Encoding.UTF8.GetBytes(rootNode.ToJsonString()), now)!;
    Check(modelCatalog.AcceptHermesStatus(noUsage, now.AddSeconds(6)), "Unavailable usage clears stale quota and pricing.");
    Check(!JsonSerializer.Serialize(modelCatalog.Projection().Tasks.Single(), WireJson.Options).Contains("modelUsage"),
        "Do not retain a previous account/model estimate after the source stops reporting it.");

    var childPacket = JsonSerializer.SerializeToUtf8Bytes(new { version = 2, state = "running", updatedAt = now.ToUnixTimeMilliseconds(),
        sessions = new[] { new { id = new string('e',64), title = "Async parent", state = "succeeded", updatedAt = now.ToUnixTimeMilliseconds(), activeSubagents = 2 } } });
    var childHeartbeat = HermesHeartbeat.Parse(childPacket, now);
    Check(childHeartbeat is not null, "Native child counts must pass the status parser.");
    var childCatalog = new TaskCatalog(); childCatalog.AcceptHermesStatus(childHeartbeat!,now);
    var parentCard = childCatalog.Projection().Tasks.Single();
    Check(parentCard.ActiveSubagents == 2 && parentCard.Lifecycle == AgentLifecycle.Running && parentCard.Activity == AgentActivity.Delegating && parentCard.CompletedAt is null,
        "Pending asynchronous children prevent false completion and expose the delegating indicator.");
    Check(JsonSerializer.Serialize(parentCard, WireJson.Options).Contains("\"activeSubagents\":2"), "Phone sees only count, not child prompts.");

    var oldHome = Environment.GetEnvironmentVariable("HERMES_HOME");
    Environment.SetEnvironmentVariable("HERMES_HOME", Path.Combine(dir.FullName, "profiles", "fixture"));
    try
    {
        var installer = new HermesPluginSetup(new byte[32]);
        Check(installer.PluginPath == Path.Combine(dir.FullName, "desktop-plugins", "agentpager-status", "plugin.js"),
            "The plugin belongs to the app-wide root even if a profile was selected.");
        Check(!installer.IsInstalled, "Report a plugin that was not installed.");
        installer.Install();
        var installed = File.ReadAllText(installer.PluginPath);
        Check(installer.IsInstalled && installed.Contains(installer.Token) && !installed.Contains("AGENTPAGER_LOCAL_STATUS_TOKEN"),
            "The Windows installer embeds only the status token into a usable plugin.");
        installer.Install();
        Check(!File.Exists(installer.PluginPath + ".bak"), "An identical reinstall does not overwrite or back up the plugin.");
        File.WriteAllText(installer.PluginPath, "fixture-old-plugin");
        installer.Install();
        Check(File.ReadAllText(installer.PluginPath + ".bak") == "fixture-old-plugin", "Repair preserves the previous plugin.");
    }
    finally { Environment.SetEnvironmentVariable("HERMES_HOME", oldHome); }

    // Run the actual Bridge endpoint: file-origin desktop succeeds, web origins,
    // wrong keys and wrong hosts do not write an observation.
    var builder = WebApplication.CreateSlimBuilder();
    builder.Logging.ClearProviders();
    builder.WebHost.UseUrls("http://127.0.0.1:0");
    await using var app = builder.Build();
    var callbacks = 0;
    HermesHeartbeat? lastAccepted = null;
    app.MapHermesStatus(key, heartbeat => { lastAccepted = heartbeat; Interlocked.Increment(ref callbacks); });
    await app.StartAsync();
    using var client = new HttpClient { BaseAddress = new Uri(app.Urls.Single()) };
    async Task<HttpStatusCode> Send(string sentKey, string origin, string? host = null)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, "/hermes-status");
        request.Headers.TryAddWithoutValidation("Origin", origin);
        if (host is not null) request.Headers.Host = host;
        request.Content = new StringContent(Encoding.UTF8.GetString(Packet(sentKey, "running", DateTimeOffset.UtcNow)),
            Encoding.UTF8, "text/plain");
        using var response = await client.SendAsync(request);
        if (response.StatusCode == HttpStatusCode.NoContent)
            Check(response.Headers.GetValues("Access-Control-Allow-Origin").Single() == "null", "Native renderer can read the acknowledgement.");
        return response.StatusCode;
    }
    Check(await Send(key, "https://example.com") == HttpStatusCode.Forbidden, "Reject normal web origins.");
    Check(await Send(key, "null", "example.com") == HttpStatusCode.Forbidden, "Reject unexpected Host headers.");
    Check(await Send(new string('0', 64), "null") == HttpStatusCode.Unauthorized, "Reject incorrect credentials.");
    Check(await Send(key, "null") == HttpStatusCode.NoContent && callbacks == 1, "Accept only the authorized heartbeat.");
    var endpointNow = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
    var endpointPacket = JsonSerializer.Serialize(new { token = key, version = 2, state = "running", updatedAt = endpointNow,
        sessions = Enumerable.Range(0, 20).Select(index => new { id = index.ToString("x64"), title = new string('文', 160), state = index == 0 ? "running" : "idle", updatedAt = endpointNow }) });
    Check(Encoding.UTF8.GetByteCount(endpointPacket) > 1_024, "Exercise a real v2 body larger than the legacy endpoint limit.");
    using (var request = new HttpRequestMessage(HttpMethod.Post, "/hermes-status"))
    {
        request.Headers.TryAddWithoutValidation("Origin", "null");
        request.Content = new StringContent(endpointPacket, Encoding.UTF8, "text/plain");
        using var response = await client.SendAsync(request);
        Check(response.StatusCode == HttpStatusCode.NoContent && callbacks == 2 && lastAccepted?.Conversations?.Count == 20,
            "The actual loopback endpoint accepts the full bounded v2 roster.");
    }
    await app.StopAsync();
    Console.WriteLine("Hermes status smoke test passed");
}
finally { dir.Delete(recursive: true); }
