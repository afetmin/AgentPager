using System.Text.Json;
using AgentPager.Core;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.Extensions.Logging;

internal static class NativeHermesTests
{
    public static async Task Run()
    {
        var builder = WebApplication.CreateSlimBuilder();
        builder.Logging.ClearProviders();
        builder.WebHost.UseUrls("http://127.0.0.1:0");
        await using var app = builder.Build();
        var calls = new List<string>();
        app.MapGet("/base/api/analytics/{kind}", (Microsoft.AspNetCore.Http.HttpRequest request, string kind) =>
        {
            if (request.Headers.Authorization != "Bearer fixture-native-secret") throw new Exception("Wrong auth header");
            if (request.Query["profile"] != "profile 中文") throw new Exception("Profile not escaped/preserved");
            calls.Add(kind + ":" + request.Query["days"]);
            return kind == "usage"
                ? JsonSerializer.Serialize(new { period_days = 90, daily = new[] { new { day = DateTimeOffset.Now.ToString("yyyy-MM-dd"), input_tokens = 5, output_tokens = 20, cache_read_tokens = 200, reasoning_tokens = 5, estimated_cost = 0.2 } } })
                : JsonSerializer.Serialize(new { period_days = int.Parse(request.Query["days"]!), models = new[] {
                    new { model = "main", provider = "route-a", input_tokens = 100, output_tokens = 20, cache_read_tokens = 10, estimated_cost = 0.2 },
                    new { model = "main", provider = "route-b", input_tokens = 10, output_tokens = 2, cache_read_tokens = 0, estimated_cost = 0.03 },
                    new { model = "aux", provider = "route-c", input_tokens = 5, output_tokens = 3, cache_read_tokens = 0, estimated_cost = 0.04 } } });
        });
        await app.StartAsync();
        using var reader = new NativeHermesUsageClient();
        var snapshot = await reader.ReadAsync(app.Urls.Single() + "/base", "profile 中文", "fixture-native-secret", CancellationToken.None);
        if (snapshot.DateBasis != "native-session-start" || snapshot.ModelUsage.Count != 0 || snapshot.IsPartial ||
            snapshot.DailyUsage.Single().TotalTokens != 225 || snapshot.DailyUsage.Single().InputTokens != 205 || snapshot.Periods?.Count != 3 ||
            snapshot.Periods.Any(p => p.TotalTokens != 150 || p.Models.Single(m => m.Model == "main").TotalTokens != 142 ||
                p.Models.Any(m => m.ReasoningEffort is not null) || Math.Abs(p.EstimatedCostUSD!.Value - 0.27) > 0.00001))
            throw new Exception("Native fixture must preserve range totals including aux and provider groups without fake dated models");
        if (!calls.Order().SequenceEqual(new[] { "models:30", "models:7", "models:90", "usage:90" }.Order()))
            throw new Exception("Native reader must request daily90 and each native range exactly once");
        if (snapshot.SourceNote is null || !snapshot.SourceNote.Contains("cache-write") || !snapshot.SourceNote.Contains("aux") ||
            !snapshot.SourceNote.Contains("费用") || snapshot.SourceNote.Contains("effort", StringComparison.OrdinalIgnoreCase) || snapshot.SourceNote.Contains("深度"))
            throw new Exception("Native coverage note must retain cache-write/daily aux/cost coverage but never display reasoning depth/effort");
        var wire = JsonSerializer.Serialize(snapshot, WireJson.Options);
        if (!wire.Contains("\"periods\"") || wire.Contains("fixture-native-secret") || wire.Contains("profile 中文"))
            throw new Exception("Native phone wire must expose periods, never URL/profile/secret");
        await NativeHermesSafetyTests.Run();
        await SettingsAndSecrets(app.Urls.Single() + "/base", () => calls.Count);
        Console.WriteLine("PASS native HTTP fixture: auth, profile, base path, daily90, periods7/30/90, aux/provider totals, coverage and wire");
    }

    private static async Task SettingsAndSecrets(string sourceUrl, Func<int> requestCount)
    {
        var root = Path.Combine(Path.GetTempPath(), "native-hermes-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var key = System.Security.Cryptography.RandomNumberGenerator.GetBytes(32);
            byte[] Encrypt(byte[] plain) { using var aes = System.Security.Cryptography.Aes.Create(); aes.Key = key; return aes.IV.Concat(aes.EncryptCbc(plain, aes.IV)).ToArray(); }
            byte[] Decrypt(byte[] data) { using var aes = System.Security.Cryptography.Aes.Create(); aes.Key = key; return aes.DecryptCbc(data.AsSpan(16), data.AsSpan(0, 16)); }
            var path = Path.Combine(root, "token.bin");
            var store = new AgentPager.Bridge.HermesAccessTokenStore(path, Encrypt, Decrypt);
            store.Save("http://localhost:7777/", "fixture-secret-never-plain");
            if (store.Load("http://localhost:7777/") != "fixture-secret-never-plain" || store.Load("http://otherhost:7777/") is not null || store.Load("http://localhost:7777/", "different-profile") is not null ||
                System.Text.Encoding.UTF8.GetString(File.ReadAllBytes(path)).Contains("fixture-secret-never-plain"))
                throw new Exception("Protected token must read back only for its bound URL and never be plaintext on disk");
            var settings = new AgentPager.Bridge.BridgeSettings { HermesServiceUrl = "http://localhost:7777/", HermesProfile = "fixture" };
            var json = JsonSerializer.Serialize(settings);
            if (json.Contains("Token", StringComparison.OrdinalIgnoreCase) || json.Contains("fixture-secret-never-plain"))
                throw new Exception("BridgeSettings must never hold any token property");
            File.WriteAllBytes(path, [1, 2, 3]);
            try { store.Load("http://localhost:7777/"); throw new Exception("Corrupt token file should not be accepted"); }
            catch (System.Security.Cryptography.CryptographicException) { }
            store.Save("http://localhost:7777/", "");
            if (File.Exists(path)) throw new Exception("Explicit token clear must remove protected file");
            await using var runtime = new AgentPager.Bridge.BridgeRuntime(new AgentPager.Bridge.BridgeSettings(), new byte[32], true, store);
            if (!runtime.TrySetHermesSource("http://localhost:7777", "fixture", "fixture-secret-never-plain", false, out var error))
                throw new Exception("Runtime failed to save validated native settings: " + error);
            var reloaded = AgentPager.Bridge.BridgeSettings.Load();
            if (reloaded.HermesServiceUrl != "http://localhost:7777/" || reloaded.HermesProfile != "fixture" || !runtime.HasHermesAccessToken ||
                File.ReadAllText(AgentPager.Core.AgentPagerPaths.SettingsFile).Contains("fixture-secret-never-plain"))
                throw new Exception("Runtime settings/secret must read back without plaintext secret");
            if (!runtime.TrySetHermesSource("http://localhost:7777/", "fixture", "", false, out error) || !runtime.HasHermesAccessToken)
                throw new Exception("Unchanged validated source must retain token when PasswordBox is blank");
            if (runtime.TrySetHermesSource("http://localhost:7777/", "another-profile", "", false, out error) || !runtime.HasHermesAccessToken)
                throw new Exception("Profile change without token/explicit anonymity must fail without losing old credential");
            var savedPath = AgentPagerPaths.SettingsFile;
            File.Move(savedPath, savedPath + ".native-backup");
            Directory.CreateDirectory(savedPath);
            try
            {
                if (runtime.TrySetHermesSource("http://localhost:7777/", "changed", "new-fixture-secret", false, out error) ||
                    runtime.Settings.HermesProfile != "fixture" || store.Load("http://localhost:7777/", "fixture") != "fixture-secret-never-plain")
                    throw new Exception("Failed settings write must roll back both protected token and active source");
            }
            finally { Directory.Delete(savedPath); File.Move(savedPath + ".native-backup", savedPath); }
            if (runtime.TrySetHermesSource("http://otherhost:7777/", null, "", false, out error))
                throw new Exception("New source needs credential or explicit anonymous choice");
            if (!runtime.TrySetHermesSource("http://otherhost:7777/", null, "", false, out error, allowAnonymous: true) || runtime.HasHermesAccessToken)
                throw new Exception("Source change must never reuse a different host's saved token");
            if (runtime.TrySetHermesSource("http://user:password@localhost:7777/", null, "", false, out error) || runtime.Settings.HermesServiceUrl != "http://otherhost:7777/")
                throw new Exception("Credential URL rejected without changing active settings");
            if (!runtime.TrySetHermesSource("", null, "", true, out error) || runtime.Settings.HermesServiceUrl is not null)
                throw new Exception("Empty URL must clear native history without fallback");
            if (Directory.GetFiles(root, "*.bin").Length != 0) throw new Exception("Token clear left file behind");
            if (!runtime.TrySetHermesSource(sourceUrl, "profile 中文", "fixture-native-secret", false, out error)) throw new Exception(error);
            using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(15));
            await runtime.StartAsync(deadline.Token, startWebListener: false);
            using var socket = await PhoneFixture.ConnectAsync(runtime, deadline.Token);
            async Task<JsonDocument> Receive()
            {
                using var bytes = new MemoryStream();
                var buffer = new byte[32768];
                System.Net.WebSockets.WebSocketReceiveResult result;
                do {
                    result = await socket.ReceiveAsync(buffer, deadline.Token);
                    await bytes.WriteAsync(buffer.AsMemory(0, result.Count), deadline.Token);
                } while (!result.EndOfMessage);
                return JsonDocument.Parse(bytes.ToArray());
            }
            while (true)
            {
                using var frame = await Receive();
                if (!frame.RootElement.GetProperty("payload").TryGetProperty("hermesUsage", out var history)) continue;
                if (history.GetProperty("dateBasis").GetString() != "native-session-start" ||
                    history.GetProperty("periods").EnumerateArray().Any(p => p.GetProperty("totalTokens").GetInt64() != 150) ||
                    history.GetProperty("modelUsage").GetArrayLength() != 0) throw new Exception("Runtime pull lost native periods");
                break;
            }
            using var client = new HttpClient();
            using var removedRoute = await client.PostAsync("http://127.0.0.1:49362/hermes-usage", new StringContent("{}"), deadline.Token);
            if (removedRoute.StatusCode != System.Net.HttpStatusCode.NotFound) throw new Exception("Removed plugin usage ingress must not exist");
            var beforeChangeRequests = requestCount();
            if (!runtime.TrySetHermesSource(sourceUrl + "/changed", null, "", false, out error, allowAnonymous: true)) throw new Exception(error);
            // Already queued frames may contain the previous snapshot; wait for the clear broadcast.
            while (true)
            {
                using var cleared = await Receive();
                if (!cleared.RootElement.GetProperty("payload").TryGetProperty("hermesUsage", out _)) break;
            }
            await Task.Delay(1200, deadline.Token);
            if (requestCount() != beforeChangeRequests || NativeHermesUsageClient.MinimumPollSeconds < 60)
                throw new Exception("Source edits must not bypass the minimum polling cadence");
            socket.Abort();
            deadline.Cancel();
            Console.WriteLine("PASS real native HTTP pull → BridgeRuntime event loop → phone WebSocket; source change clears history; /hermes-usage absent");
            Console.WriteLine("PASS protected token persistence/readback, URL binding, corrupt fail-closed, no secret settings, runtime save/change/clear");
        }
        finally { Directory.Delete(root, true); }
    }
}
