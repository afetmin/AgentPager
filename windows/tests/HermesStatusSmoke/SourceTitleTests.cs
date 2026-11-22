using System.Text;
using System.Text.Json;
using AgentPager.Core;

internal static class SourceTitleTests
{
    public static void Run()
    {
        var now = DateTimeOffset.UtcNow;
        byte[] Packet(object sessions) => JsonSerializer.SerializeToUtf8Bytes(new { version = 2, state = "running", updatedAt = now.ToUnixTimeMilliseconds(), sessions });
        var packet = Packet(new[] { new { id = new string('a', 64), title = "修复 API", agentName = "支付 Agent", state = "running", updatedAt = now.ToUnixTimeMilliseconds() },
            new { id = new string('b', 64), title = "检查文档", agentName = "文档 Agent", state = "idle", updatedAt = now.ToUnixTimeMilliseconds() } });
        var heartbeat = HermesHeartbeat.Parse(packet, now);
        Check(heartbeat is not null, "Bounded per-conversation agentName must be allowlisted without changing schema v2");
        var catalog = new TaskCatalog(); catalog.AcceptHermesStatus(heartbeat!, now);
        Check(catalog.Projection().Tasks.Any(t => t.Title == "支付 Agent · 修复 API" && t.ProjectName == "支付 Agent") &&
            catalog.Projection().Tasks.Any(t => t.Title == "文档 Agent · 检查文档"), "Each card must use its own owning agent name, not a focused agent");
        Check(!catalog.AcceptHermesStatus(heartbeat!, now.AddSeconds(2)), "Identical prefixed metadata is idempotent");
        var renamed = heartbeat! with { Conversations = heartbeat.Conversations!.Select(c => c with { Title = "新标题" }).ToArray() };
        Check(catalog.AcceptHermesStatus(renamed, now.AddSeconds(3)) && catalog.Projection().Tasks.All(t => t.Title.EndsWith(" · 新标题") && t.UpdatedAt == now), "Metadata rename must update title without lifecycle change or reordering");
        var legacy = HermesHeartbeat.Parse(Packet(new[] { new { id = new string('c', 64), title = "旧版", state = "idle", updatedAt = now.ToUnixTimeMilliseconds() } }), now)!;
        catalog.AcceptHermesStatus(legacy, now);
        Check(catalog.Projection().Tasks.Single().Title == "Hermes · 旧版", "Missing agentName stays compatible using neutral Hermes fallback");
        foreach (var invalid in new object[] { "", " ", "bad\nname", new string('x', 161), 5, null! })
            Check(HermesHeartbeat.Parse(Packet(new[] { new { id = new string('c', 64), title = "Valid", state = "idle", updatedAt = now.ToUnixTimeMilliseconds(), agentName = invalid } }), now) is null, "Reject malformed/oversized optional agentName");
        var prefixed = legacy with { Conversations = legacy.Conversations!.Select(c => c with { Title = "Hermes · 旧版" }).ToArray() };
        Check(!catalog.AcceptHermesStatus(prefixed, now), "Already-prefixed titles must not get a second prefix");
        Console.WriteLine("PASS Hermes owning agent names: bounded allowlist, legacy fallback, per-card ownership, metadata-only rename, idempotent prefix");
        WebTitles(now);
    }

    private static void WebTitles(DateTimeOffset now)
    {
        CodexHookPayload Hook(string id, string kind, string? title = null, string? prompt = null) =>
            JsonSerializer.Deserialize<CodexHookPayload>(JsonSerializer.Serialize(new { cwd = @"C:\AgentPager\ChatGPT", session_id = id, hook_event_name = kind,
                source = "app", conversation_title = title, prompt }), WireJson.Options)!;
        var id = "agentpager-chatgpt-web-" + new string('a', 64);
        var catalog = new TaskCatalog(); catalog.Accept(Hook(id, "SessionStart", "修复 API"), now);
        Check(catalog.Projection().Tasks.Single().Title == "chatgpt网页 · 修复 API", "Strict web identities must receive exact lowercase chatgpt网页 title prefix");
        catalog.Accept(Hook(id, "SessionMetadata", "重命名"), now.AddSeconds(1));
        var renamed = catalog.Projection().Tasks.Single();
        Check(renamed.Title == "chatgpt网页 · 重命名" && renamed.UpdatedAt == now, "Web metadata rename preserves prefix without reporting activity");
        catalog.Accept(Hook(id, "UserPromptSubmit", "chatgpt网页 · 重命名", "new prompt"), now.AddSeconds(2));
        Check(catalog.Projection().Tasks.Single().Title == "chatgpt网页 · 重命名", "Prompt event must not remove or double the web prefix");
        catalog.ApplyTitles(new Dictionary<string, string> { [id] = "旁路重命名" });
        Check(catalog.Projection().Tasks.Single().Title == "chatgpt网页 · 旁路重命名", "Title reader rename must preserve strict web prefix");
        var reducer = CodexEventReducer.Reduce(Hook(id, "UserPromptSubmit", prompt: "First prompt"), null, now);
        Check(reducer.Title == "chatgpt网页 · First prompt", "Web prompt fallback must not use the synthetic ChatGPT filesystem project");
        foreach (var ordinary in new[] { "regular-codex", "agentpager-chatgpt-web-not-a-hash", "agentpager-chatgpt-web-" + new string('A', 64) })
            Check(CodexEventReducer.Reduce(Hook(ordinary, "SessionStart", "普通标题"), null, now).Title == "普通标题", "Lookalike/nonweb Codex identities must not receive a web prefix");
        Check(new TaskCatalog([renamed with { Title = "历史标题" }]).Projection().Tasks.Single().Title == "chatgpt网页 · 历史标题", "Restored web titles should not wait for another lifecycle event");
        Console.WriteLine("PASS strict web title prefix across reducer, prompt, metadata, title reader, restore; ordinary Codex unchanged");
    }
    internal static void Check(bool value, string message) { if (!value) throw new Exception(message); }
}
