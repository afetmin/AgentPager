using System.Diagnostics;
using System.IO.Pipes;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Windows;
using AgentPager.Core;

namespace AgentPager.Bridge;

public static class Program
{
    private const string MutexName = "Local\\AgentPager.Bridge.Singleton";

    [STAThread]
    public static int Main(string[] args)
    {
        if (args.Contains("--hook", StringComparer.OrdinalIgnoreCase))
            return HookClient.RunAsync(args).GetAwaiter().GetResult();
        if (args.Contains("--uninstall-hook", StringComparer.OrdinalIgnoreCase))
            return Maintenance.Uninstall();

        using var mutex = new Mutex(true, MutexName, out var created);
        if (!created)
        {
            SingleInstanceSignal.Send();
            return 0;
        }

        var app = new App(
            args.Contains("--first-run", StringComparer.OrdinalIgnoreCase),
            args.Contains("--background", StringComparer.OrdinalIgnoreCase));
        return app.Run();
    }
}

internal static class HookClient
{
    public static async Task<int> RunAsync(string[] args)
    {
        var source = ResolveSource(args);
        var agentID = ResolveAgent(args);
        try
        {
            using var input = Console.OpenStandardInput();
            using var memory = new MemoryStream();
            await input.CopyToAsync(memory);
            var payloadData = memory.ToArray();

            // 按来源解码载荷，仅用于判断事件类型以设置等待时长；解析失败保持 fail-open。
            var isPermission = source == HookSource.Claude
                ? IsClaudePermission(payloadData, agentID)
                : IsCodexPermission(payloadData);

            var envelope = WrapInEnvelope(payloadData, source, agentID);
            using var client = new TcpClient();
            using var connectTimeout = new CancellationTokenSource(TimeSpan.FromMilliseconds(400));
            await client.ConnectAsync("127.0.0.1", 49361, connectTimeout.Token);
            await using var stream = client.GetStream();
            await stream.WriteAsync(envelope);
            await stream.WriteAsync("\n"u8.ToArray());
            await stream.FlushAsync();

            // 权限请求可能等用户在手机上操作很久；与 settings.json 的 hook timeout 对齐。
            var wait = isPermission
                ? (source == HookSource.Claude ? TimeSpan.FromHours(24) : TimeSpan.FromHours(1))
                : TimeSpan.FromSeconds(5);
            using var readTimeout = new CancellationTokenSource(wait);
            var response = new MemoryStream();
            var buffer = new byte[4096];
            while (true)
            {
                var count = await stream.ReadAsync(buffer, readTimeout.Token);
                if (count == 0) break;
                await response.WriteAsync(buffer.AsMemory(0, count), readTimeout.Token);
                if (buffer.AsSpan(0, count).Contains((byte)'\n')) break;
            }
            if (response.Length > 0)
            {
                response.Position = 0;
                await response.CopyToAsync(Console.OpenStandardOutput());
            }
        }
        catch (Exception error) when (error is IOException or SocketException or OperationCanceledException or JsonException)
        {
            // Hook 必须 fail-open，Bridge 不可用不能阻塞 Agent。
        }
        return 0;
    }

    private static HookSource ResolveSource(string[] args)
    {
        for (var index = 0; index < args.Length - 1; index++)
        {
            if (string.Equals(args[index], "--source", StringComparison.OrdinalIgnoreCase) &&
                Enum.TryParse<HookSource>(args[index + 1], ignoreCase: true, out var source))
                return source;
        }
        return HookSource.Codex;
    }

    /// <summary>解析 --agent &lt;id&gt;：兼容客户端（ZCode、WorkBuddy 等）的标识。</summary>
    private static string? ResolveAgent(string[] args)
    {
        for (var index = 0; index < args.Length - 1; index++)
        {
            if (string.Equals(args[index], "--agent", StringComparison.OrdinalIgnoreCase) &&
                !string.IsNullOrEmpty(args[index + 1]))
                return args[index + 1];
        }
        return null;
    }

    private static bool IsCodexPermission(byte[] payloadData)
    {
        try
        {
            var payload = JsonSerializer.Deserialize<CodexHookPayload>(payloadData, WireJson.Options);
            return payload?.HookEventName == CodexHookEventName.PermissionRequest;
        }
        catch (JsonException) { return false; }
    }

    private static bool IsClaudePermission(byte[] payloadData, string? agentID)
    {
        try
        {
            // 兼容客户端可能混用 camelCase 字段名，与桥接服务器的解码保持一致。
            var json = agentID is not null && JsonNode.Parse(payloadData) is JsonObject payloadObject
                ? HookPayloadKeyNormalizer.SnakeCasedKeys(payloadObject).ToJsonString()
                : Encoding.UTF8.GetString(payloadData);
            var payload = JsonSerializer.Deserialize<ClaudeHookPayload>(json, WireJson.Options);
            return payload?.HookEventName == "PermissionRequest";
        }
        catch (JsonException) { return false; }
    }

    /// <summary>把原始 Hook 载荷包进 {hook_source, agent_id?, payload} 信封。</summary>
    private static byte[] WrapInEnvelope(byte[] payloadData, HookSource source, string? agentID)
    {
        try
        {
            var payloadNode = JsonNode.Parse(payloadData);
            var envelope = new JsonObject
            {
                ["hook_source"] = source.ToString().ToLowerInvariant(),
                ["payload"] = payloadNode,
            };
            if (agentID is not null) envelope["agent_id"] = agentID;
            return System.Text.Encoding.UTF8.GetBytes(envelope.ToJsonString());
        }
        catch (JsonException)
        {
            // 极端情况下无法解析时退化为原样发送，服务器仍按 codex 兼容。
            return payloadData;
        }
    }
}

internal static class Maintenance
{
    public static int Uninstall()
    {
        var ok = 0;
        try { _ = new CodexHookConfiguration().Uninstall(); }
        catch { ok = 1; }
        try { _ = new ClaudeHookConfiguration().Uninstall(); }
        catch { ok = 1; }
        // 属于第三方客户端的配置可能被用户改坏，尽力清理即可，不影响整体卸载结果。
        foreach (var integration in AgentIntegrations.All)
        {
            try { _ = new AgentIntegrationConfiguration(integration).Uninstall(); }
            catch { }
        }
        try { StartupRegistration.Disable(); }
        catch { ok = 1; }
        return ok;
    }
}

internal static class SingleInstanceSignal
{
    private const string PipeName = "AgentPager.Bridge.Activate";

    public static void Send()
    {
        try
        {
            using var pipe = new NamedPipeClientStream(".", PipeName, PipeDirection.Out);
            pipe.Connect(200);
            pipe.WriteByte(1);
        }
        catch (Exception error) when (error is IOException or TimeoutException) { }
    }

    public static async Task ListenAsync(Action activate, CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested)
        {
            try
            {
                await using var pipe = new NamedPipeServerStream(PipeName, PipeDirection.In, 1,
                    PipeTransmissionMode.Byte, PipeOptions.Asynchronous);
                await pipe.WaitForConnectionAsync(cancellationToken);
                _ = pipe.ReadByte();
                activate();
            }
            catch (OperationCanceledException) { break; }
            catch (IOException) { }
        }
    }
}

public sealed class App : System.Windows.Application
{
    private readonly bool _firstRun;
    private readonly bool _background;
    private BridgeRuntime? _runtime;
    private TrayController? _tray;
    private MainWindow? _window;
    private CancellationTokenSource? _cancellation;

    public App(bool firstRun, bool background)
    {
        _firstRun = firstRun;
        _background = background;
        ShutdownMode = ShutdownMode.OnExplicitShutdown;
    }

    protected override async void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        _cancellation = new();
        _runtime = new BridgeRuntime();
        _window = new MainWindow(_runtime);
        _tray = new TrayController(_runtime, ShowWindow, ExitApplication);
        if (!_background) _runtime.Settings.Save();
        _runtime.StateChanged += () => Dispatcher.Invoke(() =>
        {
            _window.Refresh();
            _tray.Refresh();
        });
        _window.HideRequested += () => _window.Hide();
        _ = SingleInstanceSignal.ListenAsync(() => Dispatcher.Invoke(ShowWindow), _cancellation.Token);
        await _runtime.StartAsync(_cancellation.Token);
        if (_firstRun || !_runtime.Settings.HasCompletedFirstRun)
        {
            _runtime.Settings.HasCompletedFirstRun = true;
            _runtime.Settings.Save();
        }
        if (!_background) ShowWindow();
    }

    private void ShowWindow()
    {
        if (_window is null) return;
        _window.Show();
        if (_window.WindowState == WindowState.Minimized) _window.WindowState = WindowState.Normal;
        _window.Activate();
    }

    private async void ExitApplication()
    {
        _cancellation?.Cancel();
        if (_runtime is not null) await _runtime.DisposeAsync();
        _tray?.Dispose();
        Shutdown();
    }
}
