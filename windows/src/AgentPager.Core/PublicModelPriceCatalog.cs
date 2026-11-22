using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace AgentPager.Core;

/// <summary>
/// Local last-known-good catalog for API-equivalent estimates. Only a fixed public GET leaves the machine;
/// no model names, session content, tokens, account information or credentials are sent.
/// </summary>
public sealed class PublicModelPriceCatalog : IModelUsagePricing
{
    public const string Source = "https://raw.githubusercontent.com/Wei-Shaw/model-price-repo/main/model_prices_and_context_window.json";
    private static readonly HttpClient PublicClient = new(new HttpClientHandler
    {
        AllowAutoRedirect = false,
        UseCookies = false,
        Credentials = null,
        AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate,
    });
    private static readonly TimeSpan RefreshInterval = TimeSpan.FromDays(1);
    private static readonly TimeSpan RetryInterval = TimeSpan.FromHours(1);
    private sealed record Cache(string Source, DateTimeOffset FetchedAt, string Sha256, string CatalogJson);
    private readonly string _cachePath;
    private readonly HttpClient _http;
    private readonly SemaphoreSlim _refresh = new(1, 1);
    private ModelPriceCatalog? _current;
    private DateTimeOffset? _fetchedAt;
    private DateTimeOffset? _lastAttempt;

    public PublicModelPriceCatalog(string? cachePath = null, HttpClient? httpClient = null)
    {
        _cachePath = cachePath ?? Path.Combine(AgentPagerPaths.DataRoot, "model-prices.json");
        _http = httpClient ?? PublicClient;
        LoadCache();
    }

    public double? EstimateCostUSD(string? model, long inputTokens, long cachedInputTokens, long outputTokens) =>
        Volatile.Read(ref _current)?.EstimateCostUSD(model, inputTokens, cachedInputTokens, outputTokens);

    /// <returns>True when a validated public catalog was downloaded and installed.</returns>
    public async Task<bool> RefreshAsync(DateTimeOffset? now = null, bool force = false,
        CancellationToken cancellationToken = default)
    {
        await _refresh.WaitAsync(cancellationToken);
        try
        {
            var current = now ?? DateTimeOffset.UtcNow;
            if (!force && (_fetchedAt is { } fetched && current >= fetched && current - fetched < RefreshInterval ||
                _lastAttempt is { } attempted && current >= attempted && current - attempted < RetryInterval)) return false;
            _lastAttempt = current;
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeout.CancelAfter(TimeSpan.FromSeconds(10));
            using var request = new HttpRequestMessage(HttpMethod.Get, Source);
            request.Headers.Accept.ParseAdd("application/json");
            using var response = await _http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeout.Token);
            // Do not follow redirects: the endpoint cannot turn into a private or credential-bearing request.
            if (response.StatusCode != HttpStatusCode.OK ||
                response.Content.Headers.ContentLength > ModelPriceCatalog.MaximumBytes) return false;
            await using var stream = await response.Content.ReadAsStreamAsync(timeout.Token);
            using var body = new MemoryStream();
            var buffer = new byte[16 * 1024];
            int read;
            while ((read = await stream.ReadAsync(buffer, timeout.Token)) > 0)
            {
                if (body.Length + read > ModelPriceCatalog.MaximumBytes) return false;
                body.Write(buffer, 0, read);
            }
            var bytes = body.ToArray();
            var catalog = ModelPriceCatalog.Parse(bytes);
            Volatile.Write(ref _current, catalog);
            _fetchedAt = current;
            // A read-only cache directory must not disable otherwise valid in-memory prices.
            try { SaveCache(new(Source, current, Convert.ToHexString(SHA256.HashData(bytes)), Encoding.UTF8.GetString(bytes))); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
            return true;
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested) { return false; }
        catch (Exception error) when (error is HttpRequestException or IOException or JsonException) { return false; }
        finally { _refresh.Release(); }
    }

    private void LoadCache()
    {
        try
        {
            using var file = new FileStream(_cachePath, FileMode.Open, FileAccess.Read, FileShare.Read);
            if (file.Length > ModelPriceCatalog.MaximumBytes * 2) return;
            var cache = JsonSerializer.Deserialize<Cache>(file);
            if (cache is null || cache.Source != Source || cache.CatalogJson is null) return;
            var bytes = Encoding.UTF8.GetBytes(cache.CatalogJson);
            // Hash checks local cache integrity, not remote authenticity (provided by fixed HTTPS).
            if (!string.Equals(cache.Sha256, Convert.ToHexString(SHA256.HashData(bytes)), StringComparison.Ordinal)) return;
            _current = ModelPriceCatalog.Parse(bytes);
            _fetchedAt = cache.FetchedAt;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException) { }
    }

    private void SaveCache(Cache cache)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(_cachePath))!);
        var temporary = _cachePath + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            File.WriteAllText(temporary, JsonSerializer.Serialize(cache));
            File.Move(temporary, _cachePath, true);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
}
