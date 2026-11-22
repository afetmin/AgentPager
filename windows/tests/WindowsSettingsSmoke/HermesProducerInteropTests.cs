using System.Diagnostics;
using System.Net;
using System.Net.WebSockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using AgentPager.Bridge;
using AgentPager.Core;

internal static class HermesProducerInteropTests
{
    public static async Task Run()
    {
        var root = Path.Combine(Path.GetTempPath(), "agentpager-producer-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(root);
        var variables = new[] { "CODEX_HOME", "CLAUDE_CONFIG_DIR", "HERMES_HOME", "HERMES_DESKTOP_USER_DATA_DIR" };
        var old = variables.ToDictionary(k => k, Environment.GetEnvironmentVariable);
        foreach (var key in variables) Environment.SetEnvironmentVariable(key, Path.Combine(root, key));
        try
        {
            var repo = new DirectoryInfo(Directory.GetCurrentDirectory());
            while (repo is not null && !File.Exists(Path.Combine(repo.FullName, "hermes", "producer-trace.test.mjs"))) repo = repo.Parent;
            Check(repo is not null, "Cannot locate the real Hermes producer trace test");
            var trace = Path.Combine(root, "trace.json");
            var start = new ProcessStartInfo("node") { UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true, WorkingDirectory = repo!.FullName };
            start.ArgumentList.Add("--test"); start.ArgumentList.Add("hermes/producer-trace.test.mjs"); start.Environment["AGENTPAGER_HERMES_TRACE"] = trace;
            using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(40));
            using (var node = Process.Start(start)!)
            {
                var stdout = node.StandardOutput.ReadToEndAsync(); var stderr = node.StandardError.ReadToEndAsync();
                await node.WaitForExitAsync(deadline.Token);
                Check(node.ExitCode == 0 && File.Exists(trace), "Real Node producer fixture failed: " + await stdout + await stderr);
            }
            var phases = JsonNode.Parse(File.ReadAllText(trace))!.AsArray(); Check(phases.Count == 3, "Need all three genuine producer phases");
            var secret = RandomNumberGenerator.GetBytes(32);
            var setup = new HermesPluginSetup(secret);
            Directory.CreateDirectory(Path.GetDirectoryName(setup.PluginPath)!);
            using (var stream = typeof(HermesProducerInteropTests).Assembly.GetManifestResourceStream("AgentPager.Tests.LegacyPlugin.js")!)
            using (var reader = new StreamReader(stream)) File.WriteAllText(setup.PluginPath, (await reader.ReadToEndAsync()).Replace("AGENTPAGER_LOCAL_STATUS_TOKEN", new string('1', 64)));
            await using var runtime = new BridgeRuntime(new BridgeSettings(), secret, true);
            Check(runtime.State.HermesPluginUpdateStatus.Contains("已安全更新") && File.ReadAllText(setup.PluginPath).Contains(setup.Token), "Real runtime startup must upgrade a known legacy script and bind the embedded status token");
            Check(Directory.GetFiles(Path.GetDirectoryName(setup.PluginPath)!, "plugin.js.bak*").Length == 1, "Startup upgrade must create one backup");
            await runtime.StartAsync(deadline.Token, startWebListener: false);
            using var http = new HttpClient();
            long lastAt = 0;
            for (var index = 0; index < phases.Count; index++)
            {
                var packet = phases[index]!.DeepClone();
                // Only rebase the clock for network replay; states/counts/names are actual JS output.
                var at = Math.Max(DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(), lastAt + 1); lastAt = at;
                packet["updatedAt"] = at; packet["token"] = setup.Token;
                foreach (var row in packet["sessions"]!.AsArray()) row!["updatedAt"] = at;
                using var response = await http.PostAsync("http://127.0.0.1:49362/hermes-status", new StringContent(packet.ToJsonString(), Encoding.UTF8, "text/plain"), deadline.Token);
                Check(response.StatusCode == HttpStatusCode.NoContent, "The actual status endpoint rejected genuine producer metadata");
                while (runtime.State.HermesLastReceivedAt?.ToUnixTimeMilliseconds() != at) await Task.Delay(5, deadline.Token);
                // Reconnect also reads the authoritative snapshot when a pure heartbeat deliberately emits no broadcast.
                using var socket = await PhoneFixture.ConnectAsync(runtime, deadline.Token);
                using var bytes = new MemoryStream(); var buffer = new byte[32768]; WebSocketReceiveResult frame;
                do { frame = await socket.ReceiveAsync(buffer, deadline.Token); bytes.Write(buffer, 0, frame.Count); } while (!frame.EndOfMessage);
                var wire = Encoding.UTF8.GetString(bytes.ToArray());
                var envelope = JsonSerializer.Deserialize<MessageEnvelope<StateSnapshotPayload>>(wire, WireJson.Options)!;
                var payload = envelope.Payload;
                Check(payload.EnabledSources!.SequenceEqual(new[] { "hermes" }), "Offline/installed source inventory must survive producer traffic");
                var parent = payload.Tasks.Single(t => t.Title == "验收助手 · 父会话");
                var other = payload.Tasks.Single(t => t.Title == "验收助手 · 另一个会话");
                Check(other.Lifecycle == AgentLifecycle.Idle && other.ActiveSubagents == 0, "Unrelated conversation must remain idle");
                Check(parent.ProjectName == "验收助手" && parent.ActiveSubagents == (index < 2 ? 2 : 0) &&
                    parent.Lifecycle == (index < 2 ? AgentLifecycle.Running : AgentLifecycle.Succeeded) &&
                    (index < 2 ? parent.Activity == AgentActivity.Delegating && parent.CompletedAt is null : parent.CompletedAt is not null), "Parent activity/completion must follow real producer child-work evidence");
                Check(!wire.Contains("PRIVATE", StringComparison.Ordinal) && !wire.Contains(setup.Token, StringComparison.Ordinal), "No private SDK bodies/goals or bridge token may reach the phone");
                socket.Abort();
            }
            deadline.Cancel();
            Console.WriteLine("PASS production JS (mock SDK) → authenticated /hermes-status → real BridgeRuntime → phone WebSocket: parent child2/complete-still2/child0-success, agent prefix, independent idle; startup legacy auto-upgrade and backup");
        }
        finally
        {
            foreach (var value in old) Environment.SetEnvironmentVariable(value.Key, value.Value);
            Directory.Delete(root, true);
        }
    }
    private static void Check(bool value, string message) { if (!value) throw new Exception(message); }
}
