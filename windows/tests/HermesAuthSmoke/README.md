# Hermes account-auth smoke

Run with the repository's .NET 8 SDK:

```sh
dotnet run --project windows/tests/HermesAuthSmoke -p:EnableWindowsTargeting=true
```

This links the production `BridgeRuntime`, protected credential store and Core HTTP clients. It creates an isolated child user-data directory and live loopback HTTP fixtures; no NAS, auth configuration, plugin or real account is changed. The same cases also run from `WindowsSettingsSmoke`.

Coverage: basic-provider discovery, one password POST, exact/suffixed session-cookie allowlist, bearer identity verification, native refresh with rotated-token verification, protected restart/source binding, settings-save rollback, concurrent refresh, background refresh → native analytics → phone WebSocket, logout/source revision fences, refresh/analytics401 re-login state, 429, redirects/body-next refusal, response bounds, cancellation, unreachable service and secret exclusion from settings/phone messages.

The encryption boundary is injected AES on Linux; production remains Windows current-user DPAPI with no plaintext fallback. These tests do **not** execute Windows DPAPI or native WPF interactions and do not claim real-user NAS login verification. Login-cookie tokens that a gated Hermes gateway Webapp refuses as standalone bearer tokens are rejected, not reported as successful; this password client targets dashboards accepting verified `basic` bearer sessions. Logout removes only this application's local credential; it does not claim server-side revocation.

Windows-targeting build:

```sh
dotnet build windows/src/AgentPager.Bridge/AgentPager.Bridge.csproj -c Release -p:EnableWindowsTargeting=true
```
