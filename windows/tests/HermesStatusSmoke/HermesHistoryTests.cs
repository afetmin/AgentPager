using System.Text;
using System.Text.Json;
using AgentPager.Core;

internal static class HermesHistoryTests
{
    public static void Run()
    {
        var now = DateTimeOffset.UtcNow;
        var token = new string('2', 64);
        var usage = new { capturedAt = now.ToUnixTimeMilliseconds(), dateBasis = "session-start", isPartial = false,
            dailyUsage = new[] { new { date = now.ToString("yyyy-MM-dd"), inputTokens = 100, outputTokens = 20,
                cachedInputTokens = 10, reasoningOutputTokens = 5, totalTokens = 120 } },
            modelUsage = new[] { new { date = now.ToString("yyyy-MM-dd"), model = "model-a", totalTokens = 120 } } };
        var packet = JsonSerializer.SerializeToUtf8Bytes(new { version = 1, token, usage });
        var history = HermesUsageSnapshot.Parse(packet, now, token);
        if (history?.DailyUsage.Single().TotalTokens != 120 || history.DailyUsage[0].EstimatedCostUSD is not null)
            throw new Exception("History must preserve ALL counters and unknown cost");
        if (HermesUsageSnapshot.Parse(packet, now, new string('3',64)) is not null)
            throw new Exception("History must authenticate");
        if (HermesUsageSnapshot.Parse(packet, now.AddMinutes(4), token) is not null)
            throw new Exception("History replay rejected");
        var node = System.Text.Json.Nodes.JsonNode.Parse(packet)!;
        node["usage"]!["modelUsage"]![0]!["preview"] = "PRIVATE";
        if (HermesUsageSnapshot.Parse(Encoding.UTF8.GetBytes(node.ToJsonString()),now,token) is not null)
            throw new Exception("No accidental private fields accepted");
        var wire = JsonSerializer.Serialize(new StateSnapshotPayload([], null, null, []) { HermesUsage = history }, WireJson.Options);
        if (!wire.Contains("\"hermesUsage\"") || wire.Contains("PRIVATE")) throw new Exception("History wire contract");
        Console.WriteLine("Hermes history parser and phone wire tests passed");
    }
}
