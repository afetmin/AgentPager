using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace AgentPager.Core;

public sealed record ModelUsagePoint(string Date, string Model, long TotalTokens, string? ReasoningEffort = null);

public sealed record ModelTokenTotal(string Model, long TotalTokens, string? ReasoningEffort = null);
public sealed record HermesUsagePeriod(int Days, List<ModelTokenTotal> Models, long TotalTokens,
    double? EstimatedCostUSD, bool IsPartial = false);

public sealed record HermesUsageSnapshot(DateTimeOffset CapturedAt, List<DailyUsagePoint> DailyUsage,
    List<ModelUsagePoint> ModelUsage, bool IsPartial, string DateBasis)
{
    public List<HermesUsagePeriod>? Periods { get; init; }
    public string? SourceNote { get; init; }
    public const int MaximumBytes = 1024 * 1024;
    private const long MaximumTokens = 9_000_000_000_000_000;

    public static HermesUsageSnapshot? Parse(ReadOnlyMemory<byte> json, DateTimeOffset now, string token)
    {
        if (json.Length > MaximumBytes || token.Length != 64) return null;
        try
        {
            using var doc = JsonDocument.Parse(json, new JsonDocumentOptions { MaxDepth = 6 });
            var root = doc.RootElement;
            if (!Only(root, "version", "token", "usage") || !root.GetProperty("version").TryGetInt32(out var version) || version != 1 ||
                root.GetProperty("token").GetString() is not { Length: 64 } supplied ||
                !CryptographicOperations.FixedTimeEquals(Encoding.UTF8.GetBytes(token), Encoding.UTF8.GetBytes(supplied))) return null;
            var usage = root.GetProperty("usage");
            if (!Only(usage,"capturedAt","dailyUsage","modelUsage","isPartial","dateBasis")) return null;
            var at = DateTimeOffset.FromUnixTimeMilliseconds(usage.GetProperty("capturedAt").GetInt64());
            if (at > now.AddSeconds(10) || now - at >= TimeSpan.FromMinutes(3)) return null;
            var basis = usage.GetProperty("dateBasis").GetString();
            if (basis is not ("session-start" or "unavailable")) return null;
            var partial = usage.GetProperty("isPartial").GetBoolean();
            var days = usage.GetProperty("dailyUsage");
            var models = usage.GetProperty("modelUsage");
            if (days.ValueKind != JsonValueKind.Array || days.GetArrayLength() > 90 ||
                models.ValueKind != JsonValueKind.Array || models.GetArrayLength() > 4186) return null;
            var daily = new List<DailyUsagePoint>();
            var dates = new Dictionary<string,long>(StringComparer.Ordinal);
            foreach (var day in days.EnumerateArray())
            {
                if (!Only(day,"date","inputTokens","outputTokens","cachedInputTokens","reasoningOutputTokens","totalTokens","estimatedCostUSD")) return null;
                var date = day.GetProperty("date").GetString();
                if (!Date(date, at) || !dates.TryAdd(date!, Count(day,"totalTokens"))) return null;
                double? cost = day.TryGetProperty("estimatedCostUSD",out var price) && price.ValueKind != JsonValueKind.Null ? price.GetDouble() : null;
                if (cost is { } value && (!double.IsFinite(value) || value < 0 || value > 1e9)) return null;
                var input = Count(day,"inputTokens"); var output = Count(day,"outputTokens");
                var cached = Count(day,"cachedInputTokens"); var reasoning = Count(day,"reasoningOutputTokens");
                if (input + output != dates[date!] || cached > input || reasoning > output) return null;
                daily.Add(new(date!, input, cached, output, reasoning, dates[date!], cost));
            }
            var points = new List<ModelUsagePoint>();
            var sums = new Dictionary<string,long>(StringComparer.Ordinal);
            foreach (var model in models.EnumerateArray())
            {
                if (!Only(model,"date","model","totalTokens","reasoningEffort")) return null;
                var date = model.GetProperty("date").GetString();
                var name = model.GetProperty("model").GetString();
                var effort = model.TryGetProperty("reasoningEffort",out var e) ? e.GetString() : null;
                if (date is null || !dates.ContainsKey(date) || string.IsNullOrWhiteSpace(name) || name.Length > 160 || name.Any(char.IsControl) ||
                    effort is { } s && (s.Length is < 1 or > 24 || s.Any(ch => !char.IsAsciiLetterOrDigit(ch) && ch is not ('-' or '_')))) return null;
                var tokens = Count(model,"totalTokens");
                sums[date] = checked(sums.GetValueOrDefault(date) + tokens);
                points.Add(new(date,name,tokens,effort));
            }
            if (dates.Any(pair => sums.GetValueOrDefault(pair.Key) != pair.Value)) return null;
            return new(at,daily,points,partial,basis);
        }
        catch (Exception e) when (e is JsonException or InvalidOperationException or KeyNotFoundException or ArgumentOutOfRangeException or FormatException or OverflowException) { return null; }
    }

    private static long Count(JsonElement row,string name)
    {
        var n = row.GetProperty(name).GetInt64();
        return n is >= 0 and <= MaximumTokens ? n : throw new FormatException();
    }
    private static bool Date(string? date,DateTimeOffset at) => DateOnly.TryParseExact(date,"yyyy-MM-dd",CultureInfo.InvariantCulture,DateTimeStyles.None,out var parsed)
        && parsed >= DateOnly.FromDateTime(at.UtcDateTime).AddDays(-91) && parsed <= DateOnly.FromDateTime(at.UtcDateTime).AddDays(1);
    private static bool Only(JsonElement row,params string[] names) => row.ValueKind == JsonValueKind.Object &&
        row.EnumerateObject().All(p => names.Contains(p.Name,StringComparer.Ordinal)) &&
        row.EnumerateObject().Select(p => p.Name).Distinct(StringComparer.Ordinal).Count() == row.EnumerateObject().Count();
}
