using AgentPager.Core;
using System.Text.Json;

internal static class QuotaChronologyTests
{
    public static void Run()
    {
        var home = Path.Combine(Path.GetTempPath(), $"agentpager-quota-{Guid.NewGuid():N}");
        var sessions = Directory.CreateDirectory(Path.Combine(home, "sessions")).FullName;
        var now = new DateTimeOffset(2026, 11, 22, 5, 43, 0, TimeSpan.Zero);
        var previousHome = Environment.GetEnvironmentVariable("CODEX_HOME");
        Environment.SetEnvironmentVariable("CODEX_HOME", home);
        try
        {
            var touched = Path.Combine(sessions, "rollout-touched.jsonl");
            var active = Path.Combine(sessions, "rollout-active.jsonl");
            var oldWrite = now.AddHours(-3).UtcDateTime;
            File.WriteAllText(touched, Event(now.AddDays(-5), 98, 54));
            File.SetLastWriteTimeUtc(touched, now.UtcDateTime);
            var latest = now.AddMinutes(-3);
            File.WriteAllText(active, Event(latest, 100, 95) + Event(now.AddHours(-1), 94, 93));
            File.SetLastWriteTimeUtc(active, oldWrite);

            var loader = new CodexUsageLoader();
            Check(loader.Load(now), latest, 100, 95);
            Check(loader.Load(now), latest, 100, 95); // warm cache uses the same event ordering

            // New appends do not necessarily advance the file's mtime. Model-specific quotas
            // and malformed records must not displace the main Codex pair.
            File.AppendAllText(active, Event(now.AddMinutes(1), 99, 94) + Event(now.AddMinutes(2), 10, 20, "codex_other")
                + Event("not-a-date", 50, 50));
            File.SetLastWriteTimeUtc(active, oldWrite);
            Check(loader.Load(now.AddMinutes(2)), now.AddMinutes(1), 99, 94);
            Console.WriteLine("PASS quota event chronology across touched old logs, out-of-order records, cached live growth and unrelated limit buckets");
        }
        finally
        {
            Environment.SetEnvironmentVariable("CODEX_HOME", previousHome);
            Directory.Delete(home, true);
        }
    }

    private static string Event(object at, int five, int week, string? limit = "codex") => JsonSerializer.Serialize(new {
        timestamp = at, type = "event_msg", payload = new { type = "token_count", rate_limits = new {
            limit_id = limit, primary = new { used_percent = 100 - five, window_minutes = 300 },
            secondary = new { used_percent = 100 - week, window_minutes = 10080 }
        } }
    }) + "\n";

    private static void Check(UsageSnapshot? quota, DateTimeOffset at, double five, double week)
    {
        if (quota?.CapturedAt != at || quota.Windows.Count != 2 ||
            quota.Windows[0].RemainingPercentage != five || quota.Windows[1].RemainingPercentage != week)
            throw new InvalidOperationException("Expected the complete quota pair from the newest main Codex event (not the latest file mtime or final line).");
    }
}
