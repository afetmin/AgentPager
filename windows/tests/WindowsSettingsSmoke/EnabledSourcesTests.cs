using System.Net.WebSockets;
using System.Text.Json;
using AgentPager.Bridge;
using AgentPager.Core;

internal static class EnabledSourcesTests
{
    public static async Task Run()
    {
        var old = new[] { "CODEX_HOME", "CLAUDE_CONFIG_DIR", "HERMES_HOME" }.ToDictionary(k => k, Environment.GetEnvironmentVariable);
        var root = Path.Combine(Path.GetTempPath(), "agentpager-sources-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(root);
        Environment.SetEnvironmentVariable("CODEX_HOME", Path.Combine(root, "codex"));
        Environment.SetEnvironmentVariable("CLAUDE_CONFIG_DIR", Path.Combine(root, "claude"));
        Environment.SetEnvironmentVariable("HERMES_HOME", Path.Combine(root, "hermes"));
        var persistence = new TaskSnapshotPersistence();
        try
        {
            // A cached card is not proof that a source is still enabled.
            var catalog = new TaskCatalog();
            var hook = JsonSerializer.Deserialize<CodexHookPayload>("{\"cwd\":\"C:/cached\",\"session_id\":\"cached\",\"hook_event_name\":\"SessionStart\"}", WireJson.Options)!;
            catalog.Accept(hook);
            catalog.Accept(new ClaudeHookPayload("C:/cached-claude", "SessionStart", "cached-claude"));
            persistence.Save(catalog.Projection().Tasks);
            using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(50));
            await using var runtime = new BridgeRuntime(new BridgeSettings { WebMonitoringEnabled = true }, new byte[32], true);
            await runtime.StartAsync(deadline.Token, startWebListener: false);
            using (var http = new HttpClient())
            using (var response = await http.GetAsync("http://127.0.0.1:49362/pairing", deadline.Token))
                if (response.StatusCode != System.Net.HttpStatusCode.NotFound)
                    throw new Exception("Windows must never expose pairing credentials over HTTP, even on loopback");
            await PhoneSecurityTests.RejectUnsafeConnections(runtime, deadline.Token);
            using (var secure = await PhoneFixture.ConnectAsync(runtime, deadline.Token))
            {
                await PhoneSecurityTests.VerifySignedControl(secure, PhoneFixture.Pairing(runtime), deadline.Token);
                secure.Abort();
            }
            using var socket = await PhoneFixture.ConnectAsync(runtime, deadline.Token);
            async Task Sources(params string[] expected)
            {
                while (true)
                {
                    using var bytes = new MemoryStream(); var buffer = new byte[32768]; WebSocketReceiveResult frame;
                    do { frame = await socket.ReceiveAsync(buffer, deadline.Token); bytes.Write(buffer, 0, frame.Count); } while (!frame.EndOfMessage);
                    using var json = JsonDocument.Parse(bytes.ToArray());
                    if (json.RootElement.GetProperty("type").GetString() != "state.snapshot") continue;
                    var payload = json.RootElement.GetProperty("payload");
                    Check(payload.TryGetProperty("enabledSources", out var sources), "New Windows producer must explicitly publish enabledSources, including []");
                    if (sources.EnumerateArray().Select(v => v.GetString()).SequenceEqual(expected)) break;
                }
            }
            await Sources(); // Web enabled and stale Codex task are deliberately insufficient.
            runtime.InstallClaudeHook(); await Sources("claude");
            var claude = new ClaudeHookConfiguration();
            var claudeSettings = System.Text.Json.Nodes.JsonNode.Parse(File.ReadAllText(claude.SettingsPath))!;
            claudeSettings["disableAllHooks"] = true; File.WriteAllText(claude.SettingsPath, claudeSettings.ToJsonString());
            Check(!claude.IsInstalled(), "A globally disabled Claude hook must not advertise an enabled integration"); await Sources();
            claudeSettings["disableAllHooks"] = false; File.WriteAllText(claude.SettingsPath, claudeSettings.ToJsonString()); await Sources("claude");
            runtime.UninstallClaudeHook(); await Sources();
            runtime.InstallHook(); await Sources("codex");
            runtime.UninstallHook(); await Sources();
            Directory.CreateDirectory(Path.Combine(CodexPaths.Home, "sessions")); await Sources("codex");
            Directory.Delete(Path.Combine(CodexPaths.Home, "sessions")); await Sources();
            runtime.InstallHermesPlugin(); await Sources("hermes");
            // No heartbeat has ever arrived: installed/disconnected is enabled, not off.
            File.Delete(runtime.State.HermesPluginPath); await Sources();
            Check(runtime.TrySetHermesSource("http://127.0.0.1:1/", null, "", false, out _, allowAnonymous: true), "Fixture HTTP settings rejected"); await Sources("hermes");
            Check(runtime.TrySetHermesSource("", null, "", true, out _), "Fixture source removal rejected"); await Sources();
            Check(runtime.State.TaskCount == 2, "Configuration-only broadcasts must work without task mutations");
            var legacy = JsonSerializer.Deserialize<StateSnapshotPayload>("{\"tasks\":[],\"pendingRequests\":[]}", WireJson.Options)!;
            Check(!JsonSerializer.Serialize(legacy, WireJson.Options).Contains("enabledSources"), "Absent legacy field remains unknown/null, not an empty list");
            socket.Abort(); deadline.Cancel();
            Console.WriteLine("PASS real runtime → phone WebSocket enabledSources: explicit empty, hook install/uninstall, external rollout-directory detection, installed offline Hermes/HTTP, no stale-task/web false positive, legacy null");
        }
        finally
        {
            persistence.Save([]);
            foreach (var item in old) Environment.SetEnvironmentVariable(item.Key, item.Value);
            Directory.Delete(root, true);
        }
    }
    private static void Check(bool value, string message) { if (!value) throw new Exception(message); }
}
