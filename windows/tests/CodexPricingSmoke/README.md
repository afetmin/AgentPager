# Codex daily API-equivalent USD smoke tests

From the repository root:

```sh
dotnet run --project windows/tests/CodexPricingSmoke -p:EnableWindowsTargeting=true
# Optional: also exercise the real fixed HTTPS source and persisted offline cache.
dotnet run --project windows/tests/CodexPricingSmoke -p:EnableWindowsTargeting=true -- --live
```

These are executable assertions with no test-framework dependency. A failed assertion exits nonzero. Default tests do not contact the network or read the user's Codex sessions. Fixtures and caches are isolated under `TMPDIR` (falling back to the platform temporary directory) and removed afterward.

## Semantics

- Resolve each usage increment using its current `turn_context` model, or an explicit model on the usage event. Exact public-catalog model names only; no family/provider-prefix guesses.
- Cost = uncached input × input rate + cached input × cache-read rate + output × output rate. Reasoning output is a subset of output, not a second charge. Published long-context tiers apply per usage increment.
- Any nonempty usage with an unknown model or missing required rate makes that whole day's cost unknown (`null`), never a partial total. Known empty days are zero.
- Repeated cumulative totals / quota references do not add another request. Cumulative counter resets use the recorded last usage. Large rollouts are streamed, not assigned wholesale to the last day/model.
- Preserve the existing quota windows and `dailyUsage[].estimatedCostUSD` wire field.

## Catalog lifecycle and privacy

`PublicModelPriceCatalog` makes only an unauthenticated GET to its fixed public HTTPS source (the model-price-repo catalog used by Sub2API). It sends no usage, model selections, account information, local paths or session content. Redirects and cookies are disabled for the production client. The response is limited to 4 MiB with a ten-second timeout; parser depth, model count and numeric rates are validated.

The production cache is `%LOCALAPPDATA%/AgentPager/model-prices.json`. It records the fixed source, fetch time, SHA-256 integrity hash and catalog. Writes are atomic. Startup can use the last valid disk cache offline; failed or invalid refreshes retain it. Normal refresh interval is one day, failure retry backoff one hour; callers can force refresh. A cache-write failure still permits validated in-memory prices.

These are **current public standard API-equivalent reference estimates, not actual charges**, subscription consumption or historical invoices. Current catalog rates are applied to the retained daily history. They do not reconstruct priority/flex/batch discounts, taxes, account-specific pricing or separate tool charges.
