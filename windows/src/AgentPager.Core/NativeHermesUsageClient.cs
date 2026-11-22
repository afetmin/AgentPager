using System.Globalization;
using System.Net;
using System.Text.Json;

namespace AgentPager.Core;

/// <summary>Read-only dashboard analytics. Never follows redirects or shares browser credentials.</summary>
public sealed class NativeHermesUsageClient : IDisposable
{
    public const int MinimumPollSeconds = 60;
    public const string CoverageNote = "Hermes 原生统计：按服务端本地会话开始日归属；日图仅主模型，不含每日 aux 辅助用量；范围总量含可用的主/aux 模型计数。缺少 cache-write 计数。费用为原生估算，正用量的零/缺失价格按未知处理，不代表免费。";
    private const long MaximumTokens = 9_000_000_000_000_000;
    private readonly HttpClient _http = HermesCredentialTransport.CreateClient(HermesUsageSnapshot.MaximumBytes);

    public static Uri ValidateBaseUrl(string value)
    {
        if (string.IsNullOrWhiteSpace(value) || value.Length > 2048 || value.Any(char.IsWhiteSpace) ||
            value.Contains('?') || value.Contains('#') || value.Contains('\\') ||
            !Uri.TryCreate(value, UriKind.Absolute, out var uri) || uri.Scheme is not ("http" or "https") ||
            string.IsNullOrEmpty(uri.Host) || uri.UserInfo.Length != 0 || uri.Query.Length != 0 || uri.Fragment.Length != 0)
            throw new ArgumentException("请输入 http/https 服务地址和端口；不得包含凭据、查询参数或片段。");
        return new Uri(uri.AbsoluteUri.TrimEnd('/') + "/");
    }

    public static string? ValidateProfile(string? profile)
    {
        if (string.IsNullOrWhiteSpace(profile)) return null;
        if (profile.Length > 128 || profile.Any(char.IsControl)) throw new ArgumentException("Profile 最多 128 字符，不能包含控制字符。");
        return profile;
    }

    public static void ValidateToken(string token)
    {
        if (token.Length > 8192 || token.Any(c => c < 0x21 || c > 0x7e))
            throw new ArgumentException("访问令牌格式无效。");
    }

    public async Task<HermesUsageSnapshot> ReadAsync(string baseUrl, string? profile, string token, CancellationToken cancellationToken)
    {
        var uri = ValidateBaseUrl(baseUrl);
        profile = ValidateProfile(profile);
        ValidateToken(token);
        if (token.Length > 0) HermesCredentialTransport.RequireSecure(uri);
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        deadline.CancelAfter(TimeSpan.FromSeconds(35));
        var daily = new List<DailyUsagePoint>();
        var periods = new List<HermesUsagePeriod>();
        var incomplete = false;
        var successes = 0;
        try
        {
            using var document = await Get("usage", 90);
            daily = ReadDaily(document.RootElement);
            successes++;
        }
        catch (Exception e) when (Recoverable(e)) { cancellationToken.ThrowIfCancellationRequested(); incomplete = true; }
        foreach (var days in new[] { 7, 30, 90 })
        {
            try
            {
                using var document = await Get("models", days);
                periods.Add(ReadPeriod(document.RootElement, days));
                successes++;
            }
            catch (Exception e) when (Recoverable(e)) { cancellationToken.ThrowIfCancellationRequested(); incomplete = true; }
        }
        if (successes == 0) throw new IOException("无法读取 Hermes 原生统计；请检查地址、访问令牌、Profile 和服务端认证。");
        return new(DateTimeOffset.UtcNow, daily, [], incomplete, "native-session-start") { Periods = periods, SourceNote = CoverageNote };

        async Task<JsonDocument> Get(string kind, int days)
        {
            var path = $"api/analytics/{kind}?days={days}" + (profile is null ? "" : "&profile=" + Uri.EscapeDataString(profile));
            using var request = new HttpRequestMessage(HttpMethod.Get, new Uri(uri, path));
            if (token.Length > 0) request.Headers.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", token);
            request.Headers.Accept.ParseAdd("application/json");
            using var response = await _http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, deadline.Token);
            if (response.StatusCode == HttpStatusCode.Unauthorized) throw new HermesAuthenticationException("Hermes 会话已失效，请重新登录。", true);
            if (response.StatusCode != HttpStatusCode.OK) throw new IOException("原生统计 HTTP 响应不可用。");
            if (response.Content.Headers.ContentLength > HermesUsageSnapshot.MaximumBytes) throw new IOException("统计响应超出大小限制。");
            await using var stream = await response.Content.ReadAsStreamAsync(deadline.Token);
            using var buffer = new MemoryStream();
            var block = new byte[8192];
            int count;
            while ((count = await stream.ReadAsync(block, deadline.Token)) > 0)
            {
                if (buffer.Length + count > HermesUsageSnapshot.MaximumBytes) throw new IOException("统计响应超出大小限制。");
                buffer.Write(block, 0, count);
            }
            var result = JsonDocument.Parse(buffer.ToArray(), new JsonDocumentOptions { MaxDepth = 16 });
            if (!result.RootElement.TryGetProperty("period_days", out var period) || !period.TryGetInt32(out var actual) || actual != days)
            { result.Dispose(); throw new FormatException("统计范围不匹配。"); }
            return result;
        }
    }

    private static List<DailyUsagePoint> ReadDaily(JsonElement root)
    {
        var rows = Rows(root, "daily", 92);
        var daily = new List<DailyUsagePoint>();
        var dates = new HashSet<string>(StringComparer.Ordinal);
        foreach (var row in rows.EnumerateArray())
        {
            var date = row.GetProperty("day").GetString();
            if (!DateOnly.TryParseExact(date, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out _) || !dates.Add(date!))
                throw new FormatException("日统计日期无效。");
            var input = Count(row, "input_tokens");
            var output = Count(row, "output_tokens");
            var cached = Count(row, "cache_read_tokens");
            var reasoning = Count(row, "reasoning_tokens");
            // Hermes CanonicalUsage stores uncached input separately from cache reads.
            // Unlike OpenAI/Codex wire prompt tokens, cached reads may exceed input.
            if (reasoning > output) throw new FormatException("日统计计数无效。");
            var prompt = checked(input + cached);
            var total = checked(prompt + output);
            if (total > MaximumTokens) throw new FormatException("日统计计数无效。");
            daily.Add(new(date!, prompt, cached, output, reasoning, total, Cost(row, total)));
        }
        return daily.OrderBy(d => d.Date, StringComparer.Ordinal).ToList();
    }

    private static HermesUsagePeriod ReadPeriod(JsonElement root, int days)
    {
        var rows = Rows(root, "models", 4096);
        var models = new Dictionary<string, long>(StringComparer.Ordinal);
        var pairs = new HashSet<(string Model, string Provider)>();
        double? cost = 0;
        long total = 0;
        var partial = false;
        foreach (var row in rows.EnumerateArray())
        {
            var model = row.GetProperty("model").GetString();
            var provider = row.TryGetProperty("provider", out var p) ? p.GetString() ?? "" : "";
            if (string.IsNullOrWhiteSpace(model) || model.Length > 160 || model.Any(char.IsControl) || provider.Length > 160 || provider.Any(char.IsControl) || !pairs.Add((model, provider)))
                throw new FormatException("模型分组无效。");
            var input = Count(row, "input_tokens");
            var output = Count(row, "output_tokens");
            var cached = Count(row, "cache_read_tokens");
            var tokens = checked(input + cached + output);
            if (tokens > MaximumTokens) throw new FormatException();
            models[model] = checked(models.GetValueOrDefault(model) + tokens);
            total = checked(total + tokens);
            if (total > MaximumTokens) throw new FormatException();
            var estimate = Cost(row, tokens);
            if (estimate is null) { cost = null; partial = true; }
            else if (cost is not null) cost += estimate;
            if (!row.TryGetProperty("input_tokens", out var i) || i.ValueKind == JsonValueKind.Null ||
                !row.TryGetProperty("output_tokens", out var o) || o.ValueKind == JsonValueKind.Null) partial = true;
        }
        if (cost is > 1e9) throw new FormatException();
        return new(days, models.OrderByDescending(p => p.Value).ThenBy(p => p.Key, StringComparer.Ordinal)
            .Select(p => new ModelTokenTotal(p.Key, p.Value)).ToList(), total, cost, partial);
    }

    private static JsonElement Rows(JsonElement root, string name, int limit)
    {
        var rows = root.GetProperty(name);
        if (rows.ValueKind != JsonValueKind.Array || rows.GetArrayLength() > limit) throw new FormatException("统计行数无效。");
        return rows;
    }
    private static long Count(JsonElement row, string key)
    {
        if (!row.TryGetProperty(key, out var value) || value.ValueKind == JsonValueKind.Null) return 0;
        if (!value.TryGetInt64(out var n) || n is < 0 or > MaximumTokens) throw new FormatException("统计计数无效。");
        return n;
    }
    private static double? Cost(JsonElement row, long tokens)
    {
        if (!row.TryGetProperty("estimated_cost", out var value) || value.ValueKind == JsonValueKind.Null) return null;
        if (!value.TryGetDouble(out var cost) || !double.IsFinite(cost) || cost is < 0 or > 1e9) throw new FormatException("估算费用无效。");
        return cost == 0 && tokens > 0 ? null : cost;
    }
    private static bool Recoverable(Exception e) => e is not HermesAuthenticationException && (e is HttpRequestException or IOException or JsonException or
        FormatException or InvalidOperationException or KeyNotFoundException or OverflowException or OperationCanceledException);
    public void Dispose() => _http.Dispose();
}
