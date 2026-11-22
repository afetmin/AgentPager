using System.Text.Json;
using System.Globalization;
using System.Text.RegularExpressions;

namespace AgentPager.Core;

/// <summary>Standard public API-equivalent USD, not subscription spend or an invoice.</summary>
public interface IModelUsagePricing
{
    double? EstimateCostUSD(string? model, long inputTokens, long cachedInputTokens, long outputTokens);
}

public sealed class ModelPriceCatalog : IModelUsagePricing
{
    public const int MaximumBytes = 4 * 1024 * 1024;
    private sealed record Rates(decimal? Input, decimal? Cached, decimal? Output);
    private sealed record Price(Rates Standard, SortedDictionary<long, Rates> LongContext);
    private readonly Dictionary<string, Price> _prices;

    private ModelPriceCatalog(Dictionary<string, Price> prices) => _prices = prices;

    public static ModelPriceCatalog Parse(ReadOnlyMemory<byte> json)
    {
        if (json.Length == 0 || json.Length > MaximumBytes) throw new JsonException("Price catalog size is invalid.");
        using var document = JsonDocument.Parse(json, new JsonDocumentOptions { MaxDepth = 32 });
        if (document.RootElement.ValueKind != JsonValueKind.Object) throw new JsonException("Expected a model catalog.");
        var prices = new Dictionary<string, Price>(StringComparer.Ordinal);
        var count = 0;
        foreach (var model in document.RootElement.EnumerateObject())
        {
            if (++count > 10000) throw new JsonException("Too many model prices.");
            if (model.Name.Length is 0 or > 200 || model.Value.ValueKind != JsonValueKind.Object) continue;
            var value = model.Value;
            if (!Rate(value, "input_cost_per_token", out var input) ||
                !Rate(value, "output_cost_per_token", out var output)) continue;
            decimal? cached = Rate(value, "cache_read_input_token_cost", out var cache) ? cache : null;
            // An invalid advertised cache rate must not silently become a different rate.
            if (value.TryGetProperty("cache_read_input_token_cost", out _) && cached is null) continue;
            var tiers = new SortedDictionary<long, Rates>();
            foreach (var property in value.EnumerateObject())
            {
                var match = Regex.Match(property.Name,
                    "^(?:input_cost_per_token|output_cost_per_token|cache_read_input_token_cost)_above_([1-9][0-9]{0,5})k_tokens$",
                    RegexOptions.CultureInvariant);
                if (!match.Success) continue;
                var threshold = long.Parse(match.Groups[1].Value, CultureInfo.InvariantCulture) * 1000;
                var suffix = $"_above_{match.Groups[1].Value}k_tokens";
                tiers[threshold] = new(
                    Rate(value, "input_cost_per_token" + suffix, out var tierInput) ? tierInput : null,
                    Rate(value, "cache_read_input_token_cost" + suffix, out var tierCached) ? tierCached : null,
                    Rate(value, "output_cost_per_token" + suffix, out var tierOutput) ? tierOutput : null);
            }
            if (!prices.TryAdd(model.Name, new(new(input, cached, output), tiers))) throw new JsonException("Duplicate model price.");
        }
        if (prices.Count == 0) throw new JsonException("No valid model prices.");
        return new(prices);
    }

    public double? EstimateCostUSD(string? model, long inputTokens, long cachedInputTokens, long outputTokens)
    {
        if (inputTokens < 0 || cachedInputTokens < 0 || cachedInputTokens > inputTokens || outputTokens < 0)
            return null;
        if (inputTokens == 0 && outputTokens == 0) return 0;
        // Exact names only: a provider prefix or a model-family guess is not pricing evidence.
        if (model is null || !_prices.TryGetValue(model, out var price)) return null;
        var rates = price.Standard;
        foreach (var tier in price.LongContext)
            if (inputTokens > tier.Key) rates = tier.Value;
        if (inputTokens > cachedInputTokens && rates.Input is null ||
            cachedInputTokens > 0 && rates.Cached is null || outputTokens > 0 && rates.Output is null) return null;
        return (double)((inputTokens - cachedInputTokens) * (rates.Input ?? 0) +
            cachedInputTokens * (rates.Cached ?? 0) + outputTokens * (rates.Output ?? 0));
    }

    private static bool Rate(JsonElement value, string key, out decimal rate)
    {
        rate = 0;
        return value.TryGetProperty(key, out var item) && item.ValueKind == JsonValueKind.Number &&
            item.TryGetDecimal(out rate) && rate is >= 0 and <= 1;
    }
}
