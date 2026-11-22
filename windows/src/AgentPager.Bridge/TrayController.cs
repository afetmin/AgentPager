using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Forms;

namespace AgentPager.Bridge;

public sealed class TrayController : IDisposable
{
    private readonly BridgeRuntime _runtime;
    private readonly NotifyIcon _icon;
    private readonly ToolStripMenuItem _server;
    private readonly ToolStripMenuItem _hook;
    private readonly ToolStripMenuItem _link;
    private readonly ToolStripMenuItem _webStatus;
    private readonly ToolStripMenuItem _webToggle;
    private readonly Icon _ownedIcon;

    public TrayController(BridgeRuntime runtime, Action showWindow, Action exit)
    {
        _runtime = runtime;
        _ownedIcon = LoadIcon();
        _server = new() { Enabled = false };
        _hook = new() { Enabled = false };
        _link = new() { Enabled = false };
        _webStatus = new() { Enabled = false };
        _webToggle = new("启用 ChatGPT 网页监控", null,
            (_, _) => _runtime.SetWebMonitorEnabled(!_runtime.State.WebMonitor.Enabled));
        var menu = new ContextMenuStrip();
        menu.Items.AddRange([
            _server, _hook, _link, _webStatus, _webToggle,
            new ToolStripSeparator(),
            new ToolStripMenuItem("安装或修复 Codex Hook", null, (_, _) => _runtime.InstallHook()),
            new ToolStripMenuItem("安装或修复 Claude Code Hook", null, (_, _) => _runtime.InstallClaudeHook()),
            new ToolStripMenuItem("打开 AgentPager 设置", null, (_, _) => showWindow()),
            new ToolStripSeparator(),
            new ToolStripMenuItem("退出 AgentPager", null, (_, _) => exit()),
        ]);
        _icon = new()
        {
            Icon = _ownedIcon,
            Text = "AgentPager Bridge",
            ContextMenuStrip = menu,
            Visible = true,
        };
        _icon.DoubleClick += (_, _) => showWindow();
        Refresh();
    }

    public void Refresh()
    {
        var state = _runtime.State;
        _server.Text = $"SERVER  {state.ServiceStatus}";
        _hook.Text = $"HOOK    {(state.HookInstalled ? "READY" : "OFF")}";
        _link.Text = $"LINK    {(state.PhoneCount > 0 ? $"{state.PhoneCount} PHONE" : "WAIT")}";
        _webStatus.Text = $"WEB  {MainWindow.WebStatusLabel(state.WebMonitor)}";
        _webToggle.Checked = state.WebMonitor.Enabled;
        _icon.Text = $"AgentPager · {state.PhoneCount} 手机 · WEB {MainWindow.WebStatusLabel(state.WebMonitor)}";
    }

    private static Icon LoadIcon()
    {
        var resource = System.Windows.Application.GetResourceStream(new Uri("pack://application:,,,/Assets/agentpager-icon.png"))
            ?? throw new InvalidOperationException("缺少 AgentPager 图标资源。");
        using var bitmap = new Bitmap(resource.Stream);
        var handle = bitmap.GetHicon();
        try { return (Icon)Icon.FromHandle(handle).Clone(); }
        finally { DestroyIcon(handle); }
    }

    public void Dispose()
    {
        _icon.Visible = false;
        _icon.Dispose();
        _ownedIcon.Dispose();
    }

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DestroyIcon(IntPtr handle);
}
