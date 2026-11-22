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
    private bool _changingLogDirectory;
    private bool _settingsDisplayed;
    private string? _displayedLogDirectory;
    private bool _hermesSettingsDisplayed;
    private bool _changingHermesConnection;
    private bool _hermesLogoutNeedsRetry;
    private CancellationTokenSource? _hermesLoginCancellation;
    private DateTimeOffset _legacyStartupLastScan = DateTimeOffset.MinValue;

    public MainWindow(BridgeRuntime runtime)
    {
        _runtime = runtime;
        InitializeComponent();
        Activated += (_, _) => { RefreshLegacyWebStartup(force: true); Refresh(); };
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
        LastHookText.Text = state.LastHookAt?.ToString("yyyy-MM-dd HH:mm:ss") ?? "尚未收到";
        if (PairingTextBox.Text != state.PairingText)
        {
            PairingTextBox.Text = state.PairingText;
            PairingQrImage.Source = QrCode(state.PairingText);
        }
        HermesStatusText.Text = state.HermesLifecycle switch
        {
            AgentLifecycle.Running => "已连接 · 工作中",
            AgentLifecycle.Idle => "已连接 · 空闲",
            AgentLifecycle.Offline => "离线 · 检查 Hermes 是否打开或已连接",
            _ => state.HermesPluginInstalled ? "已安装 · 等待插件首个状态" : "未安装 Hermes 状态插件",
        };
        HermesLastSeenText.Text = state.HermesLastReceivedAt is { } seen
            ? $"最近收到：{seen.ToLocalTime():yyyy-MM-dd HH:mm:ss} · {state.HermesTransport}"
            : "最近收到：尚未收到";
        HermesPluginPath.Text = state.HermesPluginPath;
        HermesPluginUpdateText.Text = state.HermesPluginUpdateStatus;
        var web = state.WebMonitor;
        WebMonitorCheckBox.IsChecked = web.Enabled;
        WebStatusText.Text = WebStatusLabel(web);
        WebSummaryText.Text = $"CHATGPT WEB · {WebStatusLabel(web)}";
        WebSummaryText.Foreground = WebStatusText.Foreground = web.Status is "listener-error" or "browser-offline"
            ? System.Windows.Media.Brushes.OrangeRed
            : (System.Windows.Media.Brush)FindResource(web.Enabled ? "Cyan" : "Muted");
        WebHeartbeatText.Text = "最近浏览器心跳：" + (web.LastBrowserHeartbeatAt?.ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss") ?? "尚未收到");
        WebDetectionText.Text = "最近状态检测：" + (web.LastDetectionAt?.ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss") ?? "尚未检测到") +
            (web.LastDetectionAction is { } action ? $" · {action}" : "");
        WebTabsText.Text = $"监控标签页：{web.TabCount} · 活跃会话：{web.ActiveSessionCount}\n" +
            $"最近标签页侧栏行：{web.SidebarRows?.ToString() ?? "未知"} · 旋转指示器：{web.SpinningRows?.ToString() ?? "未知"}";
        WebErrorText.Text = web.LastError ?? "";
        NetworkCombo.ItemsSource = state.Networks;
        NetworkCombo.SelectedValue = state.SelectedAddress;
        RefreshSettings();
        DiagnosticText.Text = state.LastError is null
            ? $"49361/49362/49363 · {state.TaskCount} 个任务"
            : state.LastError;
        DiagnosticText.Foreground = state.LastError is null
            ? (System.Windows.Media.Brush)FindResource("Muted")
            : System.Windows.Media.Brushes.OrangeRed;
        _refreshing = false;
    }

    protected override void OnClosing(System.ComponentModel.CancelEventArgs e)
    {
        _hermesLoginCancellation?.Cancel();
        HermesPasswordBox.Clear();
        HermesAccessTokenBox.Clear();
        e.Cancel = true;
        HideRequested?.Invoke();
    }

    internal static string WebStatusLabel(WebMonitorState state) => state.Status switch
    {
        "disabled" => "已关闭",
        "listener-error" => "监听失败 · 检查旧桥接程序是否仍在运行",
        "waiting-browser" => "已启用 · 等待浏览器连接",
        "connected" => "已启用 · 浏览器已连接",
        "browser-offline" => "已启用 · 浏览器离线（心跳超时）",
        _ => "正在启动",
    };

    private void WebMonitorCheckBox_Changed(object sender, RoutedEventArgs e)
    {
        if (!_refreshing) _runtime.SetWebMonitorEnabled(WebMonitorCheckBox.IsChecked == true);
    }

    private void InstallHook_Click(object sender, RoutedEventArgs e) => _runtime.InstallHook();
    private void UninstallHook_Click(object sender, RoutedEventArgs e) => _runtime.UninstallHook();
    private void InstallClaudeHook_Click(object sender, RoutedEventArgs e) => _runtime.InstallClaudeHook();
    private void UninstallClaudeHook_Click(object sender, RoutedEventArgs e) => _runtime.UninstallClaudeHook();
    private void InstallHermesPlugin_Click(object sender, RoutedEventArgs e) => _runtime.InstallHermesPlugin();
    private void RefreshNetworks_Click(object sender, RoutedEventArgs e) => _runtime.RefreshNetworks();

    private void NetworkCombo_SelectionChanged(object sender, System.Windows.Controls.SelectionChangedEventArgs e)
    {
        if (!_refreshing && NetworkCombo.SelectedValue is string address)
            _runtime.SelectAddress(address);
    }

    private void StartupCheckBox_Changed(object sender, RoutedEventArgs e)
    {
        if (_refreshing) return;
        var result = _runtime.SetLaunchAtLogin(StartupCheckBox.IsChecked == true);
        SettingsFeedbackText.Text = result.Message;
        Refresh();
    }

    private void RefreshSettings(bool forceDirectory = false, bool forceHermes = false)
    {
        var url = _runtime.Settings.HermesServiceUrl;
        var profile = _runtime.Settings.HermesProfile;
        // Only explicit successful writes may replace edits; heartbeats update status alone.
        if (forceHermes || !_hermesSettingsDisplayed)
        {
            HermesServiceUrlBox.Text = url ?? "";
            HermesProfileBox.Text = profile ?? "";
            HermesAnonymousCheckBox.IsChecked = _runtime.Settings.HermesAllowAnonymous;
            if (!_hermesSettingsDisplayed) HermesUsernameBox.Text = _runtime.HermesSignedInUsername ?? "";
            _hermesSettingsDisplayed = true;
        }
        // Never fill a PasswordBox from the saved credential or erase an in-progress edit on heartbeat.
        HermesTokenStateText.Text = _runtime.HasHermesAccessToken
            ? "已保存所配置服务/Profile 的令牌（DPAPI）；令牌框留空保留，更换 URL/Profile 需重新录入或登录。"
            : "未保存所配置服务的令牌；通常请使用上方账号登录，也可在此录入已有令牌。";
        RefreshHermesAuthState();
        NativeHermesStatusText.Text = "用量连接：" + _runtime.HermesUsageStatus;
        var wasRefreshing = _refreshing;
        _refreshing = true;
        var startup = StartupRegistration.ReadStatus();
        StartupCheckBox.IsChecked = startup.Enabled;
        StartupStatusText.Text = startup.Message;
        StartupStatusText.Foreground = startup.Enabled == true
            ? (System.Windows.Media.Brush)FindResource("Cyan")
            : (System.Windows.Media.Brush)FindResource("Muted");
        RefreshLegacyWebStartup();
        var configured = _runtime.Settings.LogDirectory;
        // Background heartbeats must not replace an in-progress directory edit.
        if (forceDirectory || !_settingsDisplayed || configured != _displayedLogDirectory)
            LogDirectoryTextBox.Text = configured ?? AgentPagerPaths.LogsDirectory;
        _displayedLogDirectory = configured;
        _settingsDisplayed = true;
        var activeLogDirectory = _runtime.ActiveLogDirectory;
        ActiveLogDirectoryText.Text = "当前实际写入：" + activeLogDirectory;
        FooterLogDirectoryText.Text = "日志目录：" + activeLogDirectory;
        FooterLogDirectoryText.Foreground = _runtime.LogDirectoryError is null
            ? (System.Windows.Media.Brush)FindResource("Muted") : System.Windows.Media.Brushes.OrangeRed;
        DefaultLogDirectoryText.Text = "默认目录：" + AgentPagerPaths.LogsDirectory;
        LogDirectoryErrorText.Text = _runtime.LogDirectoryError ?? "";
        _refreshing = wasRefreshing;
    }

    private void RefreshLegacyWebStartup(bool force = false)
    {
        var now = DateTimeOffset.UtcNow;
        if (!force && now - _legacyStartupLastScan < TimeSpan.FromSeconds(30)) return;
        _legacyStartupLastScan = now;
        try
        {
            var entries = StartupRegistration.LegacyWebStartupEntries();
            LegacyStartupWarningText.Text = entries.Count == 0
                ? "未检测到已知旧网页监控自启动快捷方式。"
                : "检测到旧网页监控自启动，可能重复启动辅助程序：\n" +
                  string.Join("\n", entries.Select(entry => entry.Name + " · " + entry.Path));
            DisableLegacyWebStartupButton.IsEnabled = entries.Count > 0;
        }
        catch (Exception)
        {
            LegacyStartupWarningText.Text = "无法检查旧网页监控自启动；可重新激活窗口后重试。";
            DisableLegacyWebStartupButton.IsEnabled = false;
        }
    }

    private void DisableLegacyWebStartup_Click(object sender, RoutedEventArgs e)
    {
        DisableLegacyWebStartupButton.IsEnabled = false;
        try
        {
            var result = StartupRegistration.DisableLegacyWebStartup();
            SettingsFeedbackText.Text = result.Message;
        }
        catch (Exception)
        {
            SettingsFeedbackText.Text = "未能停用旧网页监控自启动；请检查启动目录权限后重试。";
        }
        finally { RefreshLegacyWebStartup(force: true); }
    }

    private void RefreshHermesAuthState()
    {
        var username = _runtime.HermesSignedInUsername;
        HermesAuthStateText.Text = username is not null
            ? "账号登录：已登录 · " + username + "（已保存来源；用量连接状态见下方）"
            : "账号登录：未登录（高级令牌或匿名访问不表示账号已登录）";
        LoginHermesButton.IsEnabled = !_changingHermesConnection;
        LogoutHermesButton.IsEnabled = !_changingHermesConnection && (username is not null || _runtime.HasHermesAccessToken || _hermesLogoutNeedsRetry);
        HermesServiceUrlBox.IsEnabled = !_changingHermesConnection;
        HermesProfileBox.IsEnabled = !_changingHermesConnection;
        HermesUsernameBox.IsEnabled = !_changingHermesConnection;
        HermesPasswordBox.IsEnabled = !_changingHermesConnection;
        HermesAdvancedTokenExpander.IsEnabled = !_changingHermesConnection;
    }

    private void SetHermesConnectionPending(bool pending)
    {
        _changingHermesConnection = pending;
        RefreshHermesAuthState();
    }

    private async void LoginHermes_Click(object sender, RoutedEventArgs e)
    {
        if (_changingHermesConnection) return;
        var password = HermesPasswordBox.Password;
        HermesPasswordBox.Clear();
        var url = HermesServiceUrlBox.Text;
        var profile = HermesProfileBox.Text;
        var username = HermesUsernameBox.Text.Trim();
        if (username.Length == 0 || password.Length == 0)
        {
            password = "";
            HermesAuthFeedbackText.Text = "请输入 Hermes 服务账号和密码（不是模型供应商 API Key）。";
            return;
        }
        using var cancellation = new CancellationTokenSource();
        _hermesLoginCancellation = cancellation;
        SetHermesConnectionPending(true);
        HermesAuthFeedbackText.Text = "正在登录 Hermes 服务…";
        try
        {
            HermesCredentialTransport.RequireSecure(NativeHermesUsageClient.ValidateBaseUrl(url.Trim()));
            var result = await _runtime.LoginHermesAsync(url, profile, username, password, cancellation.Token);
            HermesAuthFeedbackText.Text = result.Ok
                ? "登录成功；连接设置已保存，用量连接由下方状态单独显示。"
                : cancellation.IsCancellationRequested ? "登录已取消。" : "登录未完成；请检查可信服务的 URL、Profile 和账号密码。";
            if (result.Ok)
            {
                _hermesLogoutNeedsRetry = false;
                HermesAccessTokenBox.Clear();
                ClearHermesTokenCheckBox.IsChecked = false;
                RefreshSettings(forceHermes: true);
            }
        }
        catch (OperationCanceledException)
        {
            HermesAuthFeedbackText.Text = "登录已取消。";
        }
        catch (HermesAuthenticationException)
        {
            HermesAuthFeedbackText.Text = HermesCredentialTransport.HttpsRequiredMessage;
        }
        catch (Exception)
        {
            // Never surface service bodies, URLs or exceptions that may contain credentials.
            HermesAuthFeedbackText.Text = "登录失败；请检查服务连接和账号信息后重试。";
        }
        finally
        {
            password = "";
            _hermesLoginCancellation = null;
            SetHermesConnectionPending(false);
        }
    }

    private void LogoutHermes_Click(object sender, RoutedEventArgs e)
    {
        if (_changingHermesConnection) return;
        HermesPasswordBox.Clear();
        HermesAccessTokenBox.Clear();
        SetHermesConnectionPending(true);
        try
        {
            var ok = _runtime.LogoutHermes(out _);
            _hermesLogoutNeedsRetry = !ok;
            HermesAuthFeedbackText.Text = ok ? "已退出并清除本机登录凭据。" : "退出未完成；本机凭据未能更新，请重试。";
            if (ok)
            {
                ClearHermesTokenCheckBox.IsChecked = false;
                RefreshSettings(forceHermes: true);
            }
        }
        catch (Exception)
        {
            _hermesLogoutNeedsRetry = true;
            HermesAuthFeedbackText.Text = "退出失败；请重试。";
        }
        finally { SetHermesConnectionPending(false); }
    }

    private async void SaveHermesSource_Click(object sender, RoutedEventArgs e)
    {
        if (_changingHermesConnection) return;
        SetHermesConnectionPending(true);
        var url = HermesServiceUrlBox.Text;
        var profile = HermesProfileBox.Text;
        var token = HermesAccessTokenBox.Password;
        HermesAccessTokenBox.Clear();
        var clear = ClearHermesTokenCheckBox.IsChecked == true;
        var anonymous = HermesAnonymousCheckBox.IsChecked == true;
        try
        {
            if (!clear && !string.IsNullOrWhiteSpace(url))
            {
                var source = NativeHermesUsageClient.ValidateBaseUrl(url.Trim());
                var keepsSavedCredential = _runtime.HasHermesAccessToken && source.AbsoluteUri == _runtime.Settings.HermesServiceUrl &&
                    NativeHermesUsageClient.ValidateProfile(profile) == _runtime.Settings.HermesProfile;
                if (token.Length > 0 || keepsSavedCredential) HermesCredentialTransport.RequireSecure(source);
            }
            var ok = await Task.Run(() => _runtime.TrySetHermesSource(url, profile, token, clear, out _, anonymous));
            HermesConnectionFeedbackText.Text = ok
                ? "连接设置已保存并读回；后台将在允许的读取周期内验证连接。"
                : "设置未保存；请检查 URL、Profile 与令牌，或明确选择服务允许的匿名访问。";
            if (ok)
            {
                _hermesLogoutNeedsRetry = false;
                ClearHermesTokenCheckBox.IsChecked = false;
                RefreshSettings(forceHermes: true);
            }
        }
        catch (HermesAuthenticationException)
        {
            HermesConnectionFeedbackText.Text = HermesCredentialTransport.HttpsRequiredMessage;
        }
        catch (Exception)
        {
            HermesConnectionFeedbackText.Text = "连接设置未保存；请检查输入与本机凭据存储后重试。";
        }
        finally { token = ""; SetHermesConnectionPending(false); }
    }

    private void BrowseLogs_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            var dialog = new Microsoft.Win32.OpenFolderDialog
            {
                Title = "选择 AgentPager 日志目录",
                InitialDirectory = _runtime.ActiveLogDirectory,
                Multiselect = false,
            };
            if (dialog.ShowDialog(this) == true)
            {
                LogDirectoryTextBox.Text = dialog.FolderName;
                SettingsFeedbackText.Text = "已选择目录，点击“应用目录”保存。";
            }
        }
        catch (Exception error) when (IsSettingsError(error))
        {
            SettingsFeedbackText.Text = "无法浏览日志目录：" + error.Message;
        }
    }

    private async void ApplyLogs_Click(object sender, RoutedEventArgs e) =>
        await ApplyLogDirectory(LogDirectoryTextBox.Text);

    private async void ResetLogs_Click(object sender, RoutedEventArgs e) => await ApplyLogDirectory(null);

    private async Task ApplyLogDirectory(string? directory)
    {
        if (_changingLogDirectory) return;
        _changingLogDirectory = true;
        LogDirectoryButtons.IsEnabled = LogDirectoryTextBox.IsEnabled = false;
        SettingsFeedbackText.Text = "正在验证目录并保存…";
        try
        {
            var result = await Task.Run(() =>
            {
                var success = _runtime.TrySetLogDirectory(directory, out var error);
                return (success, error);
            });
            SettingsFeedbackText.Text = result.success
                ? "日志目录已保存，立即用于新日志；旧日志保留原位。"
                : "未更改日志目录：" + result.error;
            RefreshSettings(forceDirectory: result.success);
        }
        catch (Exception error) when (IsSettingsError(error))
        {
            SettingsFeedbackText.Text = "未更改日志目录：" + error.Message;
        }
        finally
        {
            _changingLogDirectory = false;
            LogDirectoryButtons.IsEnabled = LogDirectoryTextBox.IsEnabled = true;
        }
    }

    private static bool IsSettingsError(Exception error) => error is IOException or UnauthorizedAccessException or
        ArgumentException or NotSupportedException or System.Security.SecurityException or
        System.ComponentModel.Win32Exception or InvalidOperationException;

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

    private async void OpenLogs_Click(object sender, RoutedEventArgs e)
    {
        if (_changingLogDirectory) return;
        var path = _runtime.ActiveLogDirectory;
        try
        {
            if (!await Task.Run(() => Directory.Exists(path)))
                throw new IOException("当前日志目录不存在或不可访问：" + path);
            Process.Start(new ProcessStartInfo(path) { UseShellExecute = true });
        }
        catch (Exception error) when (IsSettingsError(error))
        {
            SettingsFeedbackText.Text = "无法打开日志目录：" + error.Message;
            System.Windows.MessageBox.Show(this, SettingsFeedbackText.Text, "AgentPager 日志目录",
                MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }
}
