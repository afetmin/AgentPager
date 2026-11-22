namespace AgentPager.Core;

/// <summary>Optional SDK metadata. USD is always an estimate, never a provider invoice.</summary>
public sealed record SessionModelUsage(
    int InputTokens,
    int OutputTokens,
    int TotalTokens,
    string? Model = null,
    string? Provider = null,
    double? EstimatedCostUSD = null,
    string? CostSource = null,
    SessionQuota? Quota = null)
{
    [System.Text.Json.Serialization.JsonIgnore]
    public TokenUsage Tokens => new(Input: InputTokens, Output: OutputTokens, Total: TotalTokens);
}

public sealed record SessionQuota(string Label, double UsedPercentage, string Source, long? ResetsAt = null);
