using System.Globalization;
using System.Text;
using System.Text.Json;

namespace AgentPager.Core;

public sealed class CodexUsageLoader(IModelUsagePricing? pricing = null, string? codexHome = null)
{
    private const int HistoryDays = 90;
    private sealed record Candidate(string Path, DateTimeOffset ModifiedAt, long Length);
    private sealed record FileUsage(Candidate Candidate, DateTimeOffset Start, Dictionary<string, DailyBucket> Buckets);
    private sealed record FileQuota(Candidate Candidate, UsageSnapshot? Quota);
    private readonly Dictionary<string, FileUsage> _recentFiles = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, FileQuota> _quotaFiles = new(StringComparer.OrdinalIgnoreCase);
    public void InvalidatePrices() => _recentFiles.Clear();
    private sealed class DailyBucket
    {
        public Raw Usage { get; set; } = Raw.Zero;
        public double? Cost { get; set; } = 0;
    }
    private sealed record Raw(long Input, long Cached, long Output, long Reasoning, long Total)
    {
        public static Raw Zero { get; } = new(0, 0, 0, 0, 0);
        public bool IsEmpty => Input == 0 && Cached == 0 && Output == 0 && Reasoning == 0 && Total == 0;
        public static Raw operator +(Raw left, Raw right) =>
            new(left.Input + right.Input, left.Cached + right.Cached, left.Output + right.Output,
                left.Reasoning + right.Reasoning, left.Total + right.Total);
        public Raw Subtract(Raw? previous) =>
            new(Math.Max(0, Input - (previous?.Input ?? 0)), Math.Max(0, Cached - (previous?.Cached ?? 0)),
                Math.Max(0, Output - (previous?.Output ?? 0)), Math.Max(0, Reasoning - (previous?.Reasoning ?? 0)),
                Math.Max(0, Total - (previous?.Total ?? 0)));
    }

    public UsageSnapshot? Load(DateTimeOffset? now = null, CancellationToken cancellationToken = default)
    {
        var current = now ?? DateTimeOffset.Now;
        DateTimeOffset start = current.ToLocalTime().Date.AddDays(-(HistoryDays - 1));
        var partial = false;
        var roots = new[]
        {
            Path.Combine(codexHome ?? CodexPaths.Home, "sessions"),
            Path.Combine(codexHome ?? CodexPaths.Home, "archived_sessions"),
        };
        var candidates = new List<Candidate>();
        foreach (var root in roots.Where(Directory.Exists))
        {
            try
            {
                foreach (var path in Directory.EnumerateFiles(root, "rollout-*.jsonl", SearchOption.AllDirectories))
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    try
                    {
                        var info = new FileInfo(path);
                        candidates.Add(new(path, info.LastWriteTimeUtc, info.Length));
                    }
                    catch (Exception error) when (error is IOException or UnauthorizedAccessException) { partial = true; }
                }
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { partial = true; }
        }
        if (candidates.Count == 0 && !partial)
        {
            _recentFiles.Clear();
            _quotaFiles.Clear();
            return null;
        }

        UsageSnapshot? quota = null;
        var candidatePaths = candidates.Select(value => value.Path).ToHashSet(StringComparer.OrdinalIgnoreCase);
        foreach (var path in _quotaFiles.Keys.Where(path => !candidatePaths.Contains(path)).ToArray()) _quotaFiles.Remove(path);
        foreach (var candidate in candidates)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (!_quotaFiles.TryGetValue(candidate.Path, out var cachedQuota) || cachedQuota.Candidate != candidate)
            {
                try { _quotaFiles[candidate.Path] = cachedQuota = new(candidate, LatestQuota(candidate)); }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException) { partial = true; }
            }
            // File metadata is only a cache key. Restoring old history can make its mtime look newer.
            if (cachedQuota?.Quota is { } record && (quota is null || record.CapturedAt > quota.CapturedAt))
                quota = record;
        }

        var buckets = new Dictionary<string, DailyBucket>();
        var recent = candidates.Where(value => value.ModifiedAt >= start).ToList();
        var recentPaths = recent.Select(value => value.Path).ToHashSet(StringComparer.OrdinalIgnoreCase);
        foreach (var path in _recentFiles.Keys.Where(path => !recentPaths.Contains(path)).ToArray()) _recentFiles.Remove(path);
        foreach (var candidate in recent)
        {
            cancellationToken.ThrowIfCancellationRequested();
            _recentFiles.TryGetValue(candidate.Path, out var file);
            if (file is null || file.Candidate != candidate || file.Start != start)
            {
                try
                {
                    var perFile = new Dictionary<string, DailyBucket>();
                    AggregateFile(candidate.Path, start, perFile, cancellationToken);
                    _recentFiles[candidate.Path] = file = new(candidate, start, perFile);
                }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException)
                {
                    // Keep the last complete contribution for this file, if any, and retry on the next refresh.
                    partial = true;
                }
            }
            if (file is null) continue;
            foreach (var (key, value) in file.Buckets)
            {
                if (!buckets.TryGetValue(key, out var bucket)) buckets[key] = bucket = new();
                bucket.Usage += value.Usage;
                bucket.Cost += value.Cost;
            }
        }
        if (quota is null && buckets.Count == 0 && !partial) return null;

        var daily = partial && buckets.Count == 0 ? [] : Enumerable.Range(0, HistoryDays).Select(offset =>
        {
            var date = start.AddDays(offset).ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
            var bucket = buckets.GetValueOrDefault(date);
            var usage = bucket?.Usage ?? Raw.Zero;
            return new DailyUsagePoint(date, usage.Input, usage.Cached, usage.Output, usage.Reasoning, usage.Total,
                partial ? null : bucket is null ? 0 : bucket.Cost);
        }).ToList();
        return new(quota?.CapturedAt ?? candidates.Select(value => (DateTimeOffset?)value.ModifiedAt).Max(),
            quota?.PlanType, quota?.LimitID, quota?.Windows ?? [], daily, partial);
    }

    private static UsageSnapshot? LatestQuota(Candidate candidate)
    {
        UsageSnapshot? latest = null;
        foreach (var line in TailLines(candidate.Path, 512 * 1024))
        {
            if (!line.Contains("\"token_count\"", StringComparison.Ordinal) ||
                !line.Contains("\"rate_limits\"", StringComparison.Ordinal)) continue;
            try
            {
                using var document = JsonDocument.Parse(line);
                var root = document.RootElement;
                if (root.ValueKind != JsonValueKind.Object || root.GetStringOrNull("type") != "event_msg" ||
                    !root.TryGetProperty("payload", out var payload) ||
                    payload.ValueKind != JsonValueKind.Object ||
                    payload.GetStringOrNull("type") != "token_count")
                    continue;
                JsonElement limits;
                if (payload.TryGetProperty("rate_limits", out var direct)) limits = direct;
                else if (payload.TryGetProperty("info", out var info) && info.ValueKind == JsonValueKind.Object &&
                         info.TryGetProperty("rate_limits", out var nested)) limits = nested;
                else continue;
                if (limits.ValueKind != JsonValueKind.Object) continue;
                var limitID = Scalar(limits, "limit_id");
                if (!string.IsNullOrEmpty(limitID) && !string.Equals(limitID, "codex", StringComparison.OrdinalIgnoreCase))
                    continue;
                if (!DateTimeOffset.TryParse(root.GetStringOrNull("timestamp"), CultureInfo.InvariantCulture,
                        DateTimeStyles.AssumeUniversal, out var captured) ||
                    (latest is not null && captured < latest.CapturedAt)) continue;
                var windows = new List<UsageWindow>();
                foreach (var key in new[] { "primary", "secondary" })
                {
                    if (!limits.TryGetProperty(key, out var window) ||
                        window.ValueKind != JsonValueKind.Object) continue;
                    if (!Number(window, "used_percent", out var used) || used is < 0 or > 100 || !double.IsFinite(used) ||
                        !Integer(window, "window_minutes", out var minutes) || minutes <= 0) continue;
                    DateTimeOffset? resets = Number(window, "resets_at", out var seconds) && seconds is >= 0 and <= 253402300799
                        ? DateTimeOffset.FromUnixTimeSeconds((long)seconds) : null;
                    windows.Add(new(key, WindowLabel(minutes), used, Math.Max(0, 100 - used), minutes, resets));
                }
                if (windows.Count == 0) continue;
                latest = new(captured, Scalar(limits, "plan_type"), limitID, windows, []);
            }
            catch (JsonException) { }
        }
        return latest;
    }

    private void AggregateFile(string path, DateTimeOffset start, Dictionary<string, DailyBucket> buckets,
        CancellationToken cancellationToken)
    {
        Raw? previous = null;
        string? model = null;
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete,
            bufferSize: 64 * 1024, FileOptions.SequentialScan);
        using var reader = new StreamReader(stream, Encoding.UTF8);
        while (reader.ReadLine() is { } line)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (!line.Contains("\"token_count\"", StringComparison.Ordinal) &&
                !line.Contains("\"turn_context\"", StringComparison.Ordinal) &&
                !line.Contains("\"session_meta\"", StringComparison.Ordinal)) continue;
            try
            {
                using var document = JsonDocument.Parse(line);
                var root = document.RootElement;
                if (root.ValueKind != JsonValueKind.Object || !root.TryGetProperty("payload", out var payload) ||
                    payload.ValueKind != JsonValueKind.Object) continue;
                var type = root.GetStringOrNull("type");
                if (type is "turn_context" or "session_meta")
                {
                    // A new context without a model must not inherit a possibly stale model.
                    if (type == "turn_context" || payload.GetStringOrNull("model") is not null)
                        model = payload.GetStringOrNull("model");
                    continue;
                }
                if (type != "event_msg" ||
                    !DateTimeOffset.TryParse(root.GetStringOrNull("timestamp"), out var timestamp) ||
                    payload.GetStringOrNull("type") != "token_count")
                    continue;
                var info = payload.TryGetProperty("info", out var infoValue) && infoValue.ValueKind == JsonValueKind.Object
                    ? infoValue : payload;
                var total = RawUsage(info, "total_token_usage") ?? RawUsage(payload, "total_token_usage");
                var last = RawUsage(info, "last_token_usage") ?? RawUsage(payload, "last_token_usage");
                // Quota-only updates repeat last_token_usage; an unchanged cumulative counter is a reference.
                var counterReset = total is not null && previous is not null &&
                    (total.Input < previous.Input || total.Output < previous.Output || total.Total < previous.Total);
                var delta = total is not null && previous is not null && !counterReset
                    ? total.Subtract(previous) : last ?? total;
                if (total is not null) previous = total;
                if (timestamp < start || delta is null || delta.IsEmpty) continue;
                var key = timestamp.ToLocalTime().ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
                if (!buckets.TryGetValue(key, out var bucket)) buckets[key] = bucket = new();
                bucket.Usage += delta;
                var eventModel = info.GetStringOrNull("model") ?? payload.GetStringOrNull("model") ?? model;
                bucket.Cost += delta.Total > 0 && delta.Input == 0 && delta.Output == 0
                    ? null : pricing?.EstimateCostUSD(eventModel, delta.Input, delta.Cached, delta.Output);
            }
            catch (JsonException) { }
        }
    }


    private static IEnumerable<string> TailLines(string path, int maximum)
    {
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        stream.Seek(Math.Max(0, stream.Length - maximum), SeekOrigin.Begin);
        using var reader = new StreamReader(stream, Encoding.UTF8);
        if (stream.Position > 0) _ = reader.ReadLine();
        while (reader.ReadLine() is { } line) yield return line;
    }

    private static Raw? RawUsage(JsonElement parent, string key)
    {
        if (!parent.TryGetProperty(key, out var value) || value.ValueKind != JsonValueKind.Object) return null;
        var input = Long(value, "input_tokens");
        var cached = Math.Min(input, Long(value, "cached_input_tokens", "cache_read_input_tokens"));
        var output = Long(value, "output_tokens");
        var total = Long(value, "total_tokens");
        if (total == 0) total = input + output;
        return new(input, cached, output, Long(value, "reasoning_output_tokens"), total);
    }

    private static long Long(JsonElement value, params string[] keys)
    {
        foreach (var key in keys)
            if (value.TryGetProperty(key, out var item) && item.ValueKind == JsonValueKind.Number && item.TryGetInt64(out var result))
                return result;
        return 0;
    }


    private static bool Number(JsonElement parent, string key, out double value)
    {
        value = 0;
        if (!parent.TryGetProperty(key, out var item)) return false;
        return item.ValueKind == JsonValueKind.Number && item.TryGetDouble(out value) ||
               item.ValueKind == JsonValueKind.String && double.TryParse(item.GetString(), NumberStyles.Float, CultureInfo.InvariantCulture, out value);
    }

    private static bool Integer(JsonElement parent, string key, out int value)
    {
        value = 0;
        if (!parent.TryGetProperty(key, out var item)) return false;
        return item.ValueKind == JsonValueKind.Number && item.TryGetInt32(out value) ||
               item.ValueKind == JsonValueKind.String && int.TryParse(item.GetString(), NumberStyles.Integer, CultureInfo.InvariantCulture, out value);
    }

    private static string? Scalar(JsonElement parent, string key)
    {
        if (!parent.TryGetProperty(key, out var item)) return null;
        return item.ValueKind == JsonValueKind.String ? item.GetString() : item.GetRawText();
    }

    private static string WindowLabel(int minutes)
    {
        var days = minutes / 1440;
        var hours = minutes % 1440 / 60;
        var rest = minutes % 60;
        if (days > 0 && hours == 0 && rest == 0) return $"{days}d";
        if (days > 0 && hours > 0) return $"{days}d {hours}h";
        if (hours > 0 && rest == 0) return $"{hours}h";
        return hours > 0 ? $"{hours}h {rest}m" : $"{minutes}m";
    }
}
