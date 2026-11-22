using AgentPager.Core;
using System.Text.Json;
using System.Text.Json.Serialization;

if (args is ["--serve-mobile-fixture" or "--serve-legacy-mobile-fixture"])
{
    // Only the isolated Chromium harness starts this fixture; never reuse the user's data.
    var data = Environment.GetEnvironmentVariable("XDG_DATA_HOME");
    if (string.IsNullOrWhiteSpace(data) || !Path.GetFullPath(AgentPagerPaths.DataRoot).StartsWith(
        Path.GetFullPath(data) + Path.DirectorySeparatorChar, StringComparison.Ordinal))
        throw new InvalidOperationException("Set an isolated XDG_DATA_HOME for this fixture.");
    using var identity = AgentPager.Bridge.PhoneTlsIdentity.Create();
    await using var runtime = new AgentPager.Bridge.BridgeRuntime(new() { LaunchAtLogin = false },
        System.Security.Cryptography.RandomNumberGenerator.GetBytes(32), loopbackOnly: true,
        loadPhoneIdentity: () => new System.Security.Cryptography.X509Certificates.X509Certificate2(identity));
    var integrated = args[0] == "--serve-mobile-fixture";
    await runtime.StartAsync(CancellationToken.None, startWebListener: integrated);
    if (runtime.State.LastError is not null || (integrated && !runtime.State.WebMonitor.Listening))
        throw new InvalidOperationException("Fixture bridge ports 49361–49363 and 49365 must be free.");
    // Only this isolated synthetic process passes a disposable pairing to its parent via pipe.
    Console.WriteLine("MOBILE_FIXTURE_READY " + JsonSerializer.Serialize(new
    {
        pairing = JsonSerializer.Deserialize<JsonElement>(runtime.State.PairingText),
        certificate = identity.ExportCertificatePem(),
    }));
    await Console.In.ReadLineAsync();
    return;
}

var options = new JsonSerializerOptions { PropertyNameCaseInsensitive = true };
options.Converters.Add(new JsonStringEnumConverter());
var now = DateTimeOffset.UtcNow;
var hash = new string('a', 64);
var id = "agentpager-chatgpt-web-" + hash;
CodexHookPayload Hook(string name, string session = "", string? title = null, string? previous = null) =>
    JsonSerializer.Deserialize<CodexHookPayload>(JsonSerializer.Serialize(new {
        cwd = @"C:\AgentPager\ChatGPT", hook_event_name = name, session_id = session.Length == 0 ? id : session,
        source = "app", conversation_title = title, previous_session_id = previous
    }), options)!;
void Check(bool value, string message) { if (!value) throw new Exception(message); Console.WriteLine("PASS " + message); }
Check(!CodexHookPayload.IsChatGPTWebID(id + "\n"), "web identity rejects trailing newline instead of normalizing malformed identifiers");
var explicitTitle = Hook("UserPromptSubmit", "original-codex-user") with { Prompt = "must not replace explicit title" };
explicitTitle = explicitTitle with { ConversationTitle = explicitTitle.ProjectName };
Check(CodexEventReducer.Reduce(explicitTitle, null, now).Title == explicitTitle.ConversationTitle,
    "original explicit conversation title wins even when equal to project name");
var catalog = new TaskCatalog();
Check(catalog.Accept(Hook("SessionMetadata", title: "not a task"), now), "unknown metadata accepted");
Check(catalog.Projection().Tasks.Count == 0, "metadata does not create phantom Starting task");
catalog.Accept(Hook("SessionStart"), now);
catalog.Accept(Hook("UserPromptSubmit"), now.AddSeconds(1));
var before = catalog.Projection().Tasks.Single();
catalog.Accept(Hook("SessionMetadata", title: "Renamed"), now.AddSeconds(2));
var after = catalog.Projection().Tasks.Single();
Check(after.Title == "chatgpt网页 · Renamed" && after.Lifecycle == AgentLifecycle.Running, "metadata renames without lifecycle transition");
Check(after.UpdatedAt == before.UpdatedAt, "metadata does not advance task activity timestamp");
var actual = "agentpager-chatgpt-web-" + new string('b', 64);
catalog.Accept(Hook("SessionMetadata", actual, "Actual", id), now.AddSeconds(3));
var merged = catalog.Projection().Tasks.Single();
Check(merged.Id == actual && merged.Title == "chatgpt网页 · Actual" && merged.StartedAt == before.StartedAt && merged.Lifecycle == AgentLifecycle.Running, "temporary ID merges into actual ID preserving running lifecycle");
catalog.Accept(Hook("SessionOffline", actual), now.AddSeconds(4));
Check(catalog.Projection().Tasks.Single().Lifecycle == AgentLifecycle.Offline, "lost browser is Offline not Succeeded");
catalog.Accept(Hook("UserPromptSubmit", actual), now.AddSeconds(5));
catalog.Accept(Hook("Stop", actual), now.AddSeconds(6));
catalog.Accept(Hook("UserPromptSubmit", actual), now.AddSeconds(7));
Check(catalog.Projection().Tasks.Single().CompletedAt is null, "new running turn clears stale CompletedAt");
var regular = "installed-codex-session";
catalog.Accept(Hook("UserPromptSubmit", regular), now.AddSeconds(8));
catalog.Accept(Hook("SessionMetadata", actual, "No hijack", regular), now.AddSeconds(9));
Check(catalog.Projection().Tasks.Count == 2 && catalog.Projection().Tasks.Any(t => t.Id == regular), "web rekey cannot collapse installed Codex tasks");
catalog.AcceptHermesStatus(AgentLifecycle.Running, now.AddSeconds(10));
Check(catalog.Projection().Tasks.Any(t => t.Source == AgentSource.HermesDesktop), "Hermes status remains independent");
Console.WriteLine("ALL CORE WEB MONITOR TESTS PASSED");

var clock = DateTime.UtcNow;
var events = new List<Dictionary<string, object>>();
var statusCatalog = new TaskCatalog();
var available = true;
var tracker = new ChatGPTWebStatusTracker(payload => {
    if (!available) return false;
    events.Add(payload);
    statusCatalog.Accept(JsonSerializer.Deserialize<CodexHookPayload>(JsonSerializer.Serialize(payload), options)!, clock);
    return true;
}, () => clock);
Dictionary<string, object> State(string action, string request = "one", string? h = null, string? prev = null) => new() {
    ["action"] = action, ["conversationHash"] = h ?? hash, ["requestId"] = request,
    ["mode"] = "Chat", ["previousConversationHash"] = prev ?? ""
};
tracker.Accept(State("start"));
var runningBeforeSwitch = statusCatalog.Projection().Tasks.Single();
tracker.Accept(new Dictionary<string, object> {
    ["action"] = "metadata", ["conversationHash"] = new string('d', 64), ["title"] = "Other idle conversation"
});
Check(statusCatalog.Projection().Tasks.Count == 1 && statusCatalog.Projection().Tasks.Single() == runningBeforeSwitch,
    "switching to idle metadata neither creates a task nor ends old running conversation");
tracker.Accept(State("start", "two"));
tracker.Accept(State("finish"));
Check(!events.Any(e => (string)e["hook_event_name"] == "Stop"), "one of two request finishes does not end conversation");
clock = clock.AddSeconds(101);
tracker.Tick();
Check((string)events.Last()["hook_event_name"] == "SessionOffline" && statusCatalog.Projection().Tasks.Single().Lifecycle == AgentLifecycle.Offline,
    "browser lease expiry is Offline end to end, never success");
tracker.Accept(State("heartbeat", "two"));
Check(statusCatalog.Projection().Tasks.Single().Lifecycle == AgentLifecycle.Running, "browser heartbeat resumes an expired Offline lease");
available = false;
tracker.Accept(State("rekey", h: new string('c', 64), prev: hash));
tracker.Accept(State("finish", "two", new string('c', 64)));
Check(statusCatalog.Projection().Tasks.Single().Id == id, "unacknowledged migration is retained for retry");
available = true;
tracker.Tick();
Check(statusCatalog.Projection().Tasks.Single().Id == "agentpager-chatgpt-web-" + new string('c', 64) &&
    statusCatalog.Projection().Tasks.Single().Lifecycle == AgentLifecycle.Succeeded,
    "identity retry is acknowledged before success and yields one final task");
var count = events.Count;
tracker.Accept(State("heartbeat", "two", new string('c', 64)));
Check(events.Count == count, "late heartbeat does not resurrect successfully finished generation");
var multiEvents = new List<string>();
var multi = new ChatGPTWebStatusTracker(payload => { multiEvents.Add((string)payload["hook_event_name"]); return true; }, () => clock);
var workStart = State("start", "browser-closed");
workStart["mode"] = "Work";
multi.Accept(workStart);
Check(multiEvents[0] == "UserPromptSubmit", "Work spinner likewise enters Thinking without inventing a tool use");
multi.Accept(State("start", "browser-still-open"));
clock = clock.AddSeconds(80);
multi.Accept(State("heartbeat", "browser-still-open"));
clock = clock.AddSeconds(25);
multi.Tick();
Check(!multiEvents.Contains("SessionOffline"), "one expired browser lease does not make live observers offline");
multi.Accept(State("finish", "browser-still-open"));
Check(multiEvents.Last() == "Stop", "a live observer can finish after another browser lease expires");
Console.WriteLine("ALL TRACKER/CATALOG INTEGRATION TESTS PASSED");
var stopEvents = new List<string>();
var stoppable = new ChatGPTWebStatusTracker(payload => { stopEvents.Add((string)payload["hook_event_name"]); return true; });
stoppable.Accept(State("start"));
var stopAll = typeof(ChatGPTWebStatusTracker).GetMethod("StopAll");
Check(stopAll is not null, "tracker supports disabling all web activity");
stopAll!.Invoke(stoppable, null);
Check(stopEvents.SequenceEqual(new[] { "UserPromptSubmit", "SessionOffline" }), "disable marks active web sessions Offline, not success");
stoppable.Tick();
Check(stopEvents.Count == 2, "disable clears leases so ticks cannot restart active web statuses");
await WebMonitorHttpTests.Run();
