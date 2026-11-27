using System.Text;
using System.Text.Json;
using AgentPager.Core;

internal static class CodexRolloutStatusTests
{
    public static void Run()
    {
        var root = Path.Combine(Path.GetTempPath(), "agentpager-codex-resume-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var now = DateTimeOffset.UtcNow;
            var old = now.AddDays(-2);
            var observer = new CodexRolloutObserver(root);
            var catalog = new TaskCatalog();
            string WriteHistory(string id)
            {
                var path = Path.Combine(root, $"rollout-{id}.jsonl");
                File.WriteAllText(path, JsonSerializer.Serialize(new {
                    type = "session_meta", payload = new { id, cwd = Path.Combine(root, "new-chat"), source = "vscode" }
                }) + "\n" + Event(old, "task_started") + Event(old.AddMinutes(1), "task_complete"));
                File.SetLastWriteTimeUtc(path, old.UtcDateTime);
                return path;
            }
            void AppendWithOldTimestamp(string path, DateTimeOffset at, string type)
            {
                File.AppendAllText(path, Event(at, type));
                File.SetLastWriteTimeUtc(path, old.UtcDateTime);
            }
            var resumed = WriteHistory("resumed");
            WriteHistory("untouched");
            using var writer = new FileStream(resumed, FileMode.Append, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete);
            void AppendToOpenLog(DateTimeOffset at, string type)
            {
                writer.Write(Encoding.UTF8.GetBytes(Event(at, type)));
                writer.Flush();
                File.SetLastWriteTimeUtc(resumed, old.UtcDateTime);
                Check(File.GetLastWriteTimeUtc(resumed) == old.UtcDateTime, "Fixture must retain its cold mtime while the writer is open");
            }
            Check(observer.Observe(now).Count == 0, "Old unchanged logs must not create cards at startup");
            AppendToOpenLog(now.AddSeconds(1), "task_started");
            var running = observer.Observe(now.AddSeconds(3));
            Check(running.Count == 1 && running[0].SessionID == "resumed" && running[0].Lifecycle == AgentLifecycle.Running,
                "A resumed Codex log with a fresh event and stale mtime must emit Running without replaying old activity");
            catalog.Accept(running);
            Check(catalog.Projection().Tasks.Single().Lifecycle == AgentLifecycle.Running, "The real task catalog must expose the resumed thread");
            AppendToOpenLog(now.AddSeconds(4), "task_complete");
            catalog.Accept(observer.Observe(now.AddSeconds(5)));
            var task = catalog.Projection().Tasks.Single();
            Check(task.Id == "resumed" && task.Lifecycle == AgentLifecycle.Succeeded && task.CompletedAt == now.AddSeconds(4),
                "The same resumed thread must complete on its real completion event");

            WriteHistory("restored-history-only");
            var restored = WriteHistory("restored-active");
            AppendWithOldTimestamp(restored, now.AddSeconds(5), "task_started");
            var ordinary = WriteHistory("ordinary");
            File.AppendAllText(ordinary, Event(now.AddSeconds(5), "task_started"));
            File.SetLastWriteTimeUtc(ordinary, now.AddSeconds(5).UtcDateTime);
            var fresh = observer.Observe(now.AddSeconds(6));
            Check(fresh.Count(s => s.SessionID == "restored-active") == 1 && fresh.Any(s => s.SessionID == "restored-active" && s.Lifecycle == AgentLifecycle.Running),
                "A newly visible old log must discover its fresh turn without importing expired history");
            Check(fresh.All(s => s.SessionID != "restored-history-only" && s.SessionID != "untouched"), "Stale history must not be turned into live cards");
            Check(fresh.Any(s => s.SessionID == "ordinary" && s.Lifecycle == AgentLifecycle.Running), "Ordinary fresh-mtime discovery must still work");
            Check(observer.Observe(now.AddSeconds(9)).Count == 0, "Already-read lines must not be emitted again");
            Console.WriteLine("PASS Codex status: stale-mtime resume, restored JSONL, history exclusion, normal discovery and completion");
        }
        finally { Directory.Delete(root, recursive: true); }
    }

    private static string Event(DateTimeOffset at, string type) => JsonSerializer.Serialize(new {
        timestamp = at, type = "event_msg", payload = new { type }
    }) + "\n";

    private static void Check(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
}
