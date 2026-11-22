using AgentPager.Core;
using System.Text;

if (args is ["--inspect-live-usage"])
{
    // Read-only on-device diagnostics: no titles, tokens, model names or paths in the output.
    var watch = System.Diagnostics.Stopwatch.StartNew();
    var loader = new CodexUsageLoader(new PublicModelPriceCatalog());
    var snapshot = loader.Load();
    var elapsedMs = watch.ElapsedMilliseconds;
    watch.Restart();
    var resampled = loader.Load();
    Console.WriteLine(System.Text.Json.JsonSerializer.Serialize(new {
        snapshotPresent = snapshot is not null,
        quotaWindows = snapshot?.Windows.Count ?? 0,
        hasTodayUsage = snapshot?.DailyUsage.LastOrDefault()?.TotalTokens > 0,
        hasPricedDays = snapshot?.DailyUsage.Any(day => day.TotalTokens > 0 && day.EstimatedCostUSD is not null) == true,
        partial = snapshot?.IsPartial,
        elapsedMs,
        warmElapsedMs = watch.ElapsedMilliseconds,
        warmHasUsage = resampled?.DailyUsage.LastOrDefault()?.TotalTokens > 0,
    }));
    return;
}

QuotaChronologyTests.Run();

var catalog = ModelPriceCatalog.Parse(Encoding.UTF8.GetBytes("""
{
  "gpt-test": {"input_cost_per_token":0.000002,"cache_read_input_token_cost":0.0000002,"output_cost_per_token":0.000008}
}
"""));
var estimate = catalog.EstimateCostUSD("gpt-test", 1000, 400, 200);
if (estimate is null || Math.Abs(estimate.Value - 0.00288) > 1e-12)
    throw new Exception($"Expected cached input discounted, output charged once: {estimate}");
Console.WriteLine("PASS per-model cache-aware pricing");

var home = Path.Combine(Environment.GetEnvironmentVariable("TMPDIR") ?? Path.GetTempPath(), "codex-pricing-" + Guid.NewGuid());
Directory.CreateDirectory(Path.Combine(home, "sessions"));
try
{
    var path = Path.Combine(home, "sessions", "rollout-test.jsonl");
    File.WriteAllText(path, """
    {"type":"turn_context","payload":{"model":"gpt-test"}}
    {"timestamp":"2026-11-20T10:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":400,"output_tokens":200,"reasoning_output_tokens":150,"total_tokens":1200},"last_token_usage":{"input_tokens":1000,"cached_input_tokens":400,"output_tokens":200,"reasoning_output_tokens":150,"total_tokens":1200}}}}
    {"timestamp":"2026-11-20T10:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":400,"output_tokens":200,"reasoning_output_tokens":150,"total_tokens":1200},"last_token_usage":{"input_tokens":1000,"cached_input_tokens":400,"output_tokens":200,"reasoning_output_tokens":150,"total_tokens":1200}}}}
    """);
    var day = new CodexUsageLoader(catalog, home).Load(DateTimeOffset.Parse("2026-11-20T12:00:00Z"))!.DailyUsage.Last();
    if (day.TotalTokens != 1200 || day.ReasoningOutputTokens != 150 || day.EstimatedCostUSD != estimate)
        throw new Exception($"Expected one request; reasoning is part of output, quota references are not billed: {day}");
    Console.WriteLine("PASS daily per-model pricing without repeated references or double-charged reasoning");
    File.AppendAllText(path, "\n" + """
    {"timestamp":"2026-11-20T11:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"output_tokens":20,"total_tokens":120},"last_token_usage":{"input_tokens":100,"output_tokens":20,"total_tokens":120}}}}
    """);
    var reset = new CodexUsageLoader(catalog, home).Load(DateTimeOffset.Parse("2026-11-20T12:00:00Z"))!.DailyUsage.Last();
    if (reset.TotalTokens != 1320 || Math.Abs(reset.EstimatedCostUSD!.Value - (estimate!.Value + catalog.EstimateCostUSD("gpt-test", 100, 0, 20)!.Value)) > 1e-12)
        throw new Exception($"A reset cumulative counter must still count its last request: {reset}");
    Console.WriteLine("PASS cumulative counter reset");
    File.AppendAllText(path, "\n" + """
    {"timestamp":"2026-11-20T12:00:00Z","type":"event_msg","payload":{"type":"token_count","info":null}}
    """);
    if (new CodexUsageLoader(catalog, home).Load(DateTimeOffset.Parse("2026-11-20T12:00:00Z"))!.DailyUsage.Last() != reset)
        throw new Exception("A quota-only token event with null info must not invent usage.");
    Console.WriteLine("PASS quota-only null usage");
}
finally { Directory.Delete(home, true); }

var cacheRoot = Path.Combine(Environment.GetEnvironmentVariable("TMPDIR") ?? Path.GetTempPath(), "price-cache-" + Guid.NewGuid());
Directory.CreateDirectory(cacheRoot);
try
{
    var handler = new CatalogHandler();
    using var http = new HttpClient(handler);
    var cachePath = Path.Combine(cacheRoot, "prices.json");
    var prices = new PublicModelPriceCatalog(cachePath, http);
    var now = DateTimeOffset.Parse("2026-11-20T10:00:00Z");
    if (!await prices.RefreshAsync(now)) throw new Exception("First public refresh failed.");
    if (prices.EstimateCostUSD("gpt-test", 1000, 400, 200) != estimate) throw new Exception("Fetched catalog not installed.");
    if (await prices.RefreshAsync(now.AddMinutes(10)) || handler.Calls != 1) throw new Exception("Fresh cache fetched again.");
    handler.Offline = true;
    var offline = new PublicModelPriceCatalog(cachePath, http);
    if (offline.EstimateCostUSD("gpt-test", 1000, 400, 200) != estimate) throw new Exception("Offline restart lost cached prices.");
    if (await offline.RefreshAsync(now.AddDays(2)) || offline.EstimateCostUSD("gpt-test", 1000, 400, 200) != estimate)
        throw new Exception("Offline refresh must preserve last valid prices.");
    Console.WriteLine("PASS fixed public GET, refresh interval, durable cache, offline fallback");
    var callsAfterFailure = handler.Calls;
    if (await offline.RefreshAsync(now.AddDays(2).AddMinutes(10)) || handler.Calls != callsAfterFailure)
        throw new Exception("Offline failures should back off instead of retrying every usage poll.");
    handler.Offline = false;
    handler.Body = "<html>not a catalog</html>";
    if (await offline.RefreshAsync(now.AddDays(3), force: true) || offline.EstimateCostUSD("gpt-test", 1000, 400, 200) != estimate)
        throw new Exception("An invalid response replaced last-known-good data.");
    handler.Body = new string('x', ModelPriceCatalog.MaximumBytes + 1);
    if (await offline.RefreshAsync(now.AddDays(3), force: true)) throw new Exception("Oversized response accepted.");
    handler.UnknownLength = true;
    if (await offline.RefreshAsync(now.AddDays(3), force: true)) throw new Exception("Chunked oversized response accepted.");
    handler.Status = System.Net.HttpStatusCode.Redirect;
    if (await offline.RefreshAsync(now.AddDays(3), force: true)) throw new Exception("Redirect accepted.");
    handler.Status = System.Net.HttpStatusCode.OK;
    handler.UnknownLength = false;
    handler.Body = CatalogHandler.ValidBody.Replace("0.000002", "0.000004", StringComparison.Ordinal);
    if (!await offline.RefreshAsync(now.AddDays(4), force: true) || offline.EstimateCostUSD("gpt-test", 1000, 0, 0) != 0.004)
        throw new Exception("Forced refresh did not replace stale prices.");
    var saved = File.ReadAllText(cachePath);
    File.WriteAllText(cachePath, saved.Replace("0.000004", "0.000003", StringComparison.Ordinal));
    if (new PublicModelPriceCatalog(cachePath, http).EstimateCostUSD("gpt-test", 1000, 0, 0) is not null)
        throw new Exception("Tampered cache hash was not checked.");
    File.WriteAllText(cachePath, "{");
    if (new PublicModelPriceCatalog(cachePath, http).EstimateCostUSD("gpt-test", 1000, 0, 0) is not null)
        throw new Exception("Malformed cache was accepted.");
    using var cancelled = new CancellationTokenSource();
    cancelled.Cancel();
    try { await prices.RefreshAsync(cancellationToken: cancelled.Token); throw new Exception("Caller cancellation swallowed."); }
    catch (OperationCanceledException) { }
    Console.WriteLine("PASS refresh/backoff, invalid and oversized responses, redirects, corrupt cache, cancellation");
}
finally { Directory.Delete(cacheRoot, true); }

static ModelPriceCatalog Parse(string json) => ModelPriceCatalog.Parse(Encoding.UTF8.GetBytes(json));

void Scenario(string name, string lines, Action<UsageSnapshot> verify, IModelUsagePricing? prices = null)
{
    var root = Path.Combine(Environment.GetEnvironmentVariable("TMPDIR") ?? Path.GetTempPath(), "codex-case-" + Guid.NewGuid());
    try
    {
        Directory.CreateDirectory(Path.Combine(root, "sessions"));
        File.WriteAllText(Path.Combine(root, "sessions", "rollout-test.jsonl"), lines);
        var snapshot = new CodexUsageLoader(prices ?? catalog, root).Load(DateTimeOffset.Parse("2026-11-20T12:00:00Z"));
        if (snapshot is null) throw new Exception(name + ": missing snapshot");
        verify(snapshot);
        Console.WriteLine("PASS " + name);
    }
    finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
}

string Context(string? model) => System.Text.Json.JsonSerializer.Serialize(new { type = "turn_context", payload = new { model } });
string Tokens(string timestamp, long input, long cached, long output, long? cumulativeInput = null) =>
    System.Text.Json.JsonSerializer.Serialize(new { timestamp, type = "event_msg", payload = new {
        type = "token_count", info = new { total_token_usage = new { input_tokens = cumulativeInput ?? input,
            cached_input_tokens = cached, output_tokens = output, total_tokens = (cumulativeInput ?? input) + output } } } });

var mixed = Parse("""
{"gpt-test":{"input_cost_per_token":0.000002,"cache_read_input_token_cost":0.0000002,"output_cost_per_token":0.000008},
 "expensive":{"input_cost_per_token":0.00001,"cache_read_input_token_cost":0.000001,"output_cost_per_token":0.00004}}
""");
Scenario("mixed models sum their own rates, not the final model rate", string.Join('\n',
    Context("gpt-test"), Tokens("2026-11-20T10:00:00Z", 1000, 0, 200),
    Context("expensive"), Tokens("2026-11-20T11:00:00Z", 2000, 0, 400)), snapshot => {
        var day = snapshot.DailyUsage.Last();
        var expected = mixed.EstimateCostUSD("gpt-test", 1000, 0, 200) + mixed.EstimateCostUSD("expensive", 1000, 0, 200);
        if (day.TotalTokens != 2400 || day.EstimatedCostUSD != expected) throw new Exception($"Wrong mixed model estimate: {day}");
    }, mixed);
Scenario("unknown models poison the full daily estimate, never partial totals", string.Join('\n',
    Context("unknown"), Tokens("2026-11-20T10:00:00Z", 1000, 0, 200),
    Context("gpt-test"), Tokens("2026-11-20T11:00:00Z", 2000, 0, 400)), snapshot => {
        if (snapshot.DailyUsage.Last().EstimatedCostUSD is not null || snapshot.DailyUsage.Last().TotalTokens != 2400)
            throw new Exception("Unknown model returned a misleading partial estimate.");
    });
Scenario("total-only usage has unknown cost, not free usage", """
{"timestamp":"2026-11-20T10:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":100}}}}
""", snapshot => {
    if (snapshot.DailyUsage.Last().EstimatedCostUSD is not null || snapshot.DailyUsage.Last().TotalTokens != 100)
        throw new Exception("Incomplete token components must remain unknown.");
});
Scenario("quota windows survive pricing and wire USD is serialized", string.Join('\n',
    Context("gpt-test"), Tokens("2026-11-20T10:00:00Z", 1000, 0, 200), """
    {"timestamp":"2026-11-20T11:00:00Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"primary":{"used_percent":25,"window_minutes":300,"resets_at":1795183200},"plan_type":"plus","limit_id":"codex"}}}
    """), snapshot => {
        if (snapshot.Windows.Count != 1 || snapshot.Windows[0].RemainingPercentage != 75 || snapshot.PlanType != "plus" || snapshot.LimitID != "codex")
            throw new Exception("Pricing broke quota loading.");
        using var json = System.Text.Json.JsonDocument.Parse(System.Text.Json.JsonSerializer.Serialize(snapshot, WireJson.Options));
        if (json.RootElement.GetProperty("dailyUsage")[89].GetProperty("estimatedCostUSD").GetDouble() != catalog.EstimateCostUSD("gpt-test", 1000, 0, 200))
            throw new Exception("Daily USD estimate not exposed on the existing wire field.");
    });
Scenario("missing model remains unknown", Tokens("2026-11-20T10:00:00Z", 1000, 0, 200), snapshot => {
    if (snapshot.DailyUsage.Last().EstimatedCostUSD is not null) throw new Exception("Missing model guessed.");
});
Scenario("new context clears stale model", string.Join('\n', Context("gpt-test"), Context(null),
    Tokens("2026-11-20T10:00:00Z", 1000, 0, 200)), snapshot => {
        if (snapshot.DailyUsage.Last().EstimatedCostUSD is not null) throw new Exception("Stale model inherited.");
    });
Scenario("large rollouts preserve days and model boundaries", string.Join('\n',
    Context("gpt-test"), Tokens("2026-11-19T10:00:00Z", 1000, 0, 200),
    "{\"type\":\"response_item\",\"payload\":\"" + new string('x', 300000) + "\"}",
    Context("expensive"), Tokens("2026-11-20T11:00:00Z", 2000, 0, 400)), snapshot => {
        if (snapshot.DailyUsage.Count != 90 || snapshot.DailyUsage[^2].EstimatedCostUSD != mixed.EstimateCostUSD("gpt-test", 1000, 0, 200) ||
            snapshot.DailyUsage[^1].EstimatedCostUSD != mixed.EstimateCostUSD("expensive", 1000, 0, 200) ||
            snapshot.DailyUsage[0].EstimatedCostUSD != 0) throw new Exception("Large rollout/day aggregation is wrong.");
    }, mixed);
if (catalog.EstimateCostUSD("openai/gpt-test", 1, 0, 0) is not null || catalog.EstimateCostUSD("unknown", 1, 0, 0) is not null ||
    catalog.EstimateCostUSD("gpt-test", -1, 0, 0) is not null || catalog.EstimateCostUSD("gpt-test", 1, 2, 0) is not null)
    throw new Exception("Invalid or unknown model usage was priced.");
var uncachedOnly = Parse("""{"plain":{"input_cost_per_token":0.000002,"output_cost_per_token":0.000008}}""");
if (uncachedOnly.EstimateCostUSD("plain", 1000, 1, 0) is not null || uncachedOnly.EstimateCostUSD("plain", 1000, 0, 0) is null)
    throw new Exception("Missing cache rate must only invalidate requests with cached tokens.");
foreach (var invalid in new[] { "[]", "{}", "{\"bad\":{\"input_cost_per_token\":-1,\"output_cost_per_token\":0.1}}",
    "{\"bad\":{\"input_cost_per_token\":2,\"output_cost_per_token\":0.1}}", "{\"bad\":{\"input_cost_per_token\":\"0.01\",\"output_cost_per_token\":0.1}}" })
{
    try { Parse(invalid); throw new Exception("Invalid catalog accepted: " + invalid); }
    catch (System.Text.Json.JsonException) { }
}
Console.WriteLine("PASS catalog validation, unknown exact names, missing cache rates, invalid token counts");
var tiered = Parse("""
{"tiered":{"input_cost_per_token":0.000002,"cache_read_input_token_cost":0.0000002,"output_cost_per_token":0.000008,
"input_cost_per_token_above_272k_tokens":0.000004,"cache_read_input_token_cost_above_272k_tokens":0.0000004,"output_cost_per_token_above_272k_tokens":0.000012}}
""");
if (tiered.EstimateCostUSD("tiered", 300000, 100000, 10000) != (double)(200000m * 0.000004m + 100000m * 0.0000004m + 10000m * 0.000012m) ||
    tiered.EstimateCostUSD("tiered", 272000, 0, 0) != (double)(272000m * 0.000002m))
    throw new Exception("Published long-context tiers must apply to the whole request, not marginal tokens.");
Console.WriteLine("PASS published long-context price tiers");

var liveHome = Path.Combine(Path.GetTempPath(), "codex-live-rollout-" + Guid.NewGuid().ToString("N"));
var liveSessions = Path.Combine(liveHome, "sessions");
Directory.CreateDirectory(liveSessions);
try
{
    var livePath = Path.Combine(liveSessions, "rollout-active.jsonl");
    var blockedPath = Path.Combine(liveSessions, "rollout-locked.jsonl");
    var now = DateTimeOffset.Now;
    var eventTime = now.ToString("O");
    var quotaLine = $$$$$"""{"timestamp":"{{{{{eventTime}}}}}","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":31,"window_minutes":300}}}}""";
    File.WriteAllText(livePath, string.Join('\n', Context("gpt-test"), Tokens(eventTime, 100, 0, 20), quotaLine) + "\n");
    File.WriteAllText(blockedPath, Tokens(eventTime, 50, 0, 10) + "\n");
    using var writer = new FileStream(livePath, FileMode.Append, FileAccess.Write, FileShare.ReadWrite);
    using var held = new FileStream(blockedPath, FileMode.Open, FileAccess.ReadWrite, FileShare.None);
    var liveLoader = new CodexUsageLoader(catalog, liveHome);
    var first = liveLoader.Load(now);
    if (first?.DailyUsage.Last().TotalTokens != 120 || !first.IsPartial || first.Windows.Single().UsedPercentage != 31 ||
        first.DailyUsage.Last().EstimatedCostUSD is not null)
        throw new Exception("An active writer and locked sibling must preserve available usage and quota; incomplete prices remain absent.");
    writer.Write(Encoding.UTF8.GetBytes(Tokens(eventTime, 200, 0, 40) + "\n"));
    writer.Flush();
    if (liveLoader.Load(now)?.DailyUsage.Last().TotalTokens != 240)
        throw new Exception("Appending live usage never reached the next collection.");
    held.Dispose();
    var recovered = liveLoader.Load(now);
    if (recovered?.DailyUsage.Last().TotalTokens != 300 || recovered.IsPartial)
        throw new Exception("Releasing a transient lock did not recover the previously skipped file.");
    Console.WriteLine("PASS open-writer collection, locked sibling isolation, live refresh and recovery");
}
finally { Directory.Delete(liveHome, true); }

var cacheUsageHome = Path.Combine(Path.GetTempPath(), "codex-usage-cache-" + Guid.NewGuid().ToString("N"));
try
{
    var sessions = Directory.CreateDirectory(Path.Combine(cacheUsageHome, "sessions"));
    var now = DateTimeOffset.Now;
    File.WriteAllText(Path.Combine(sessions.FullName, "rollout-current.jsonl"),
        string.Join('\n', Context("gpt-test"), Tokens(now.ToString("O"), 100, 0, 20)));
    var prices = new CountingPricing();
    var loader = new CodexUsageLoader(prices, cacheUsageHome);
    if (loader.Load(now)?.DailyUsage.Last().EstimatedCostUSD != 0.01 ||
        loader.Load(now)?.DailyUsage.Last().EstimatedCostUSD != 0.01 || prices.Calls != 1)
        throw new Exception("An unchanged rollout got re-priced on the next live poll.");
    prices.Cost = 0.02;
    loader.InvalidatePrices();
    if (loader.Load(now)?.DailyUsage.Last().EstimatedCostUSD != 0.02 || prices.Calls != 2)
        throw new Exception("Refreshed prices did not invalidate the cached rollout.");
    Console.WriteLine("PASS unchanged rollout reuse and price refresh invalidation");
}
finally { Directory.Delete(cacheUsageHome, true); }

if (args.Contains("--live", StringComparer.Ordinal))
{
    var root = Path.Combine(Environment.GetEnvironmentVariable("TMPDIR") ?? Path.GetTempPath(), "codex-live-price-" + Guid.NewGuid());
    try
    {
        var live = new PublicModelPriceCatalog(Path.Combine(root, "prices.json"));
        if (!await live.RefreshAsync(force: true)) throw new Exception("Live public catalog fetch/validation failed.");
        var cost = live.EstimateCostUSD("gpt-5", 1000, 400, 200);
        if (cost is null or <= 0 || new PublicModelPriceCatalog(Path.Combine(root, "prices.json")).EstimateCostUSD("gpt-5", 1000, 400, 200) != cost)
            throw new Exception("Live downloaded prices or persisted cache could not price a known model.");
        Console.WriteLine($"PASS live public HTTPS catalog, parser and offline cache: gpt-5 fixture estimate USD {cost:G17}");
    }
    finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
}

sealed class CountingPricing : IModelUsagePricing
{
    public int Calls { get; private set; }
    public double Cost { get; set; } = 0.01;
    public double? EstimateCostUSD(string? model, long inputTokens, long cachedInputTokens, long outputTokens)
    {
        Calls++;
        return Cost;
    }
}

sealed class CatalogHandler : HttpMessageHandler
{
    public const string ValidBody = """{"gpt-test":{"input_cost_per_token":0.000002,"cache_read_input_token_cost":0.0000002,"output_cost_per_token":0.000008}}""";
    public int Calls { get; private set; }
    public bool Offline { get; set; }
    public bool UnknownLength { get; set; }
    public string Body { get; set; } = ValidBody;
    public System.Net.HttpStatusCode Status { get; set; } = System.Net.HttpStatusCode.OK;
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        Calls++;
        if (request.Method != HttpMethod.Get || request.RequestUri?.AbsoluteUri != PublicModelPriceCatalog.Source || request.Content is not null || request.Headers.Authorization is not null)
            throw new Exception("Only the fixed public catalog GET is allowed; never upload usage or credentials.");
        if (Offline) throw new HttpRequestException("offline test");
        return Task.FromResult(new HttpResponseMessage(Status)
        {
            Content = UnknownLength ? new UnknownLengthContent(Encoding.UTF8.GetBytes(Body)) : new StringContent(Body)
        });
    }
}

sealed class UnknownLengthContent(byte[] bytes) : HttpContent
{
    protected override Task SerializeToStreamAsync(Stream stream, System.Net.TransportContext? context) => stream.WriteAsync(bytes).AsTask();
    protected override bool TryComputeLength(out long length) { length = 0; return false; }
    protected override Task<Stream> CreateContentReadStreamAsync() => Task.FromResult<Stream>(new MemoryStream(bytes));
}
