using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Media.Imaging;
using AgentPager.Core;
using QRCoder;

namespace AgentPager.Bridge;

public partial class MainWindow : Window
{
    private readonly BridgeRuntime _runtime;
    private bool _refreshing;
    private IReadOnlyList<IntegrationViewState> _renderedIntegrations = [];

    public MainWindow(BridgeRuntime runtime)
    {
        _runtime = runtime;
        InitializeComponent();
        Refresh();
    }

    public event Action? HideRequested;

    public void Refresh()
    {
        if (!Dispatcher.CheckAccess())
        {
            Dispatcher.Invoke(Refresh);
            return;
        }
        _refreshing = true;
        var state = _runtime.State;
        ServiceStatusText.Text = state.ServiceStatus;
        PhoneCountText.Text = state.PhoneCount.ToString();
        HookStatusText.Text = state.HookInstalled ? "已写入" : "未安装";
        ClaudeHookStatusText.Text = state.ClaudeHookInstalled ? "已写入" : "未安装";
        RebuildIntegrations(state.Integrations);
        LastHookText.Text = state.LastHookAt?.ToString("yyyy-MM-dd HH:mm:ss") ?? "尚未收到";
        PairingTextBox.Text = state.PairingText;
        PairingQrImage.Source = QrCode(state.PairingText);
        NetworkCombo.ItemsSource = state.Networks;
        NetworkCombo.SelectedValue = state.SelectedAddress;
        StartupCheckBox.IsChecked = _runtime.Settings.LaunchAtLogin;
        DiagnosticText.Text = state.LastError is null
            ? $"49361/49362 · {state.TaskCount} 个任务 · 数据目录 {AgentPagerPaths.DataRoot}"
            : state.LastError;
        DiagnosticText.Foreground = state.LastError is null
            ? (System.Windows.Media.Brush)FindResource("Muted")
            : System.Windows.Media.Brushes.OrangeRed;
        _refreshing = false;
    }

    /// <summary>仅在状态变化时重建，避免每个 Hook 事件都让按钮闪烁。</summary>
    private void RebuildIntegrations(IReadOnlyList<IntegrationViewState> items)
    {
        if (_renderedIntegrations.SequenceEqual(items)) return;
        _renderedIntegrations = items;
        IntegrationList.Children.Clear();
        var muted = (System.Windows.Media.Brush)FindResource("Muted");
        foreach (var item in items)
        {
            var integration = item.Integration;
            var status = item.Installed
                ? (item.Dormant ? "已写入，但客户端总开关已关闭" : "已写入")
                : item.Detected ? "未安装" : "未检测到客户端";
            var provenance = integration.Verification == IntegrationVerification.OfficialDocs
                ? "依据官方文档"
                : "社区实现 · 未真机验证";

            var panel = new System.Windows.Controls.StackPanel { Margin = new Thickness(0, 0, 0, 20) };
            panel.Children.Add(new System.Windows.Controls.TextBlock
            {
                Text = $"{integration.DisplayName} · {status}",
                FontWeight = FontWeights.Bold,
            });
            panel.Children.Add(new System.Windows.Controls.TextBlock
            {
                Text = $"{integration.DisplayConfigPath} · {provenance}",
                Foreground = muted,
                TextWrapping = TextWrapping.Wrap,
                Margin = new Thickness(0, 4, 0, 0),
            });
            if (integration.Note is not null)
                panel.Children.Add(new System.Windows.Controls.TextBlock
                {
                    Text = integration.Note,
                    Foreground = muted,
                    TextWrapping = TextWrapping.Wrap,
                    Margin = new Thickness(0, 4, 0, 0),
                });
            if (item.Error is not null)
                panel.Children.Add(new System.Windows.Controls.TextBlock
                {
                    Text = item.Error,
                    Foreground = System.Windows.Media.Brushes.OrangeRed,
                    TextWrapping = TextWrapping.Wrap,
                    Margin = new Thickness(0, 4, 0, 0),
                });

            var install = new System.Windows.Controls.Button
            {
                Content = item.Installed ? "修复" : "安装",
                IsEnabled = item.Detected,
            };
            install.Click += (_, _) => _runtime.InstallIntegration(integration.Id);
            var uninstall = new System.Windows.Controls.Button
            {
                Content = "卸载",
                BorderBrush = (System.Windows.Media.Brush)new System.Windows.Media.BrushConverter().ConvertFromString("#FF5D72")!,
                IsEnabled = item.Installed,
            };
            uninstall.Click += (_, _) => _runtime.UninstallIntegration(integration.Id);
            var buttons = new System.Windows.Controls.StackPanel
            {
                Orientation = System.Windows.Controls.Orientation.Horizontal,
                Margin = new Thickness(0, 10, 0, 0),
            };
            buttons.Children.Add(install);
            buttons.Children.Add(uninstall);
            panel.Children.Add(buttons);
            IntegrationList.Children.Add(panel);
        }
    }

    protected override void OnClosing(System.ComponentModel.CancelEventArgs e)
    {
        e.Cancel = true;
        HideRequested?.Invoke();
    }

    private void InstallHook_Click(object sender, RoutedEventArgs e) => _runtime.InstallHook();
    private void UninstallHook_Click(object sender, RoutedEventArgs e) => _runtime.UninstallHook();
    private void InstallClaudeHook_Click(object sender, RoutedEventArgs e) => _runtime.InstallClaudeHook();
    private void UninstallClaudeHook_Click(object sender, RoutedEventArgs e) => _runtime.UninstallClaudeHook();
    private void RefreshNetworks_Click(object sender, RoutedEventArgs e) => _runtime.RefreshNetworks();

    private void NetworkCombo_SelectionChanged(object sender, System.Windows.Controls.SelectionChangedEventArgs e)
    {
        if (!_refreshing && NetworkCombo.SelectedValue is string address)
            _runtime.SelectAddress(address);
    }

    private void StartupCheckBox_Changed(object sender, RoutedEventArgs e)
    {
        if (!_refreshing) _runtime.SetLaunchAtLogin(StartupCheckBox.IsChecked == true);
    }

    private void CopyPairing_Click(object sender, RoutedEventArgs e)
    {
        if (!string.IsNullOrEmpty(PairingTextBox.Text))
            System.Windows.Clipboard.SetText(PairingTextBox.Text);
    }

    private static BitmapImage QrCode(string text)
    {
        using var data = QRCodeGenerator.GenerateQrCode(text, QRCodeGenerator.ECCLevel.M);
        var bytes = new PngByteQRCode(data).GetGraphic(8);
        var image = new BitmapImage();
        using var memory = new MemoryStream(bytes);
        image.BeginInit();
        image.CacheOption = BitmapCacheOption.OnLoad;
        image.StreamSource = memory;
        image.EndInit();
        image.Freeze();
        return image;
    }

    private void OpenLogs_Click(object sender, RoutedEventArgs e)
    {
        Directory.CreateDirectory(AgentPagerPaths.LogsDirectory);
        Process.Start(new ProcessStartInfo("explorer.exe", AgentPagerPaths.LogsDirectory)
        {
            UseShellExecute = true,
        });
    }
}
