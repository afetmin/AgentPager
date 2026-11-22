using System.Security.Cryptography.X509Certificates;
using System.Text.Json;
using System.Threading.Channels;
using AgentPager.Core;

namespace AgentPager.Bridge;

public sealed record BridgeViewState(
    string ServiceStatus,
    int PhoneCount,
    bool HookInstalled,
    bool ClaudeHookInstalled,
    DateTimeOffset? LastHookAt,
    string? LastError,
    string PairingText,
    string SelectedAddress,
    List<NetworkAddressOption> Networks,
    int TaskCount,
    bool HermesPluginInstalled,
    string HermesPluginPath,
    string HermesPluginUpdateStatus,
    AgentLifecycle? HermesLifecycle,
    DateTimeOffset? HermesLastReceivedAt,
    string? HermesTransport,
    WebMonitorState WebMonitor);

public sealed partial class BridgeRuntime : IAsyncDisposable
{
    private abstract record BridgeEvent;
    private sealed record HookEvent(HookEnvelope Envelope) : BridgeEvent;
    private sealed record RolloutEvent(List<CodexRolloutSignal> Signals) : BridgeEvent;
    private sealed record ControlEvent(string Text) : BridgeEvent;
    private sealed record PhoneCountEvent(int Count) : BridgeEvent;
    private sealed record UsageEvent(UsageSnapshot? Usage) : BridgeEvent;
    private sealed record MaintenanceEvent : BridgeEvent;
    private sealed record HermesHeartbeatEvent(HermesHeartbeat Heartbeat) : BridgeEvent;
    private sealed record NativeHermesEvent(int Revision, HermesUsageSnapshot? Usage, string Status) : BridgeEvent;
    private sealed record HermesSourceChangedEvent(int Revision) : BridgeEvent;
    private sealed record WebStatusChangedEvent : BridgeEvent;
    private sealed record ConfigurationChangedEvent : BridgeEvent;
    private sealed record WebEnabledEvent(bool Enabled) : BridgeEvent;
    private sealed record WebHookEvent(CodexHookPayload Hook) : BridgeEvent;

    private readonly DailyFileLog _log;
    private readonly Channel<BridgeEvent> _events = Channel.CreateUnbounded<BridgeEvent>(
        new UnboundedChannelOptions { SingleReader = true, SingleWriter = false });
    private readonly TaskSnapshotPersistence _persistence = new();
    private readonly CodexSessionTitleReader _titleReader = new();
    private readonly CodexRolloutObserver _rollout = new();
    private readonly HermesDesktopStatus _hermesStatus = new();
    private readonly HermesPluginSetup _hermesSetup;
    private readonly ChatGPTWebMonitorHost _webMonitor;
    private readonly PublicModelPriceCatalog _modelPrices = new();
    private readonly CodexUsageLoader _usageLoader;
    private readonly CodexHookConfiguration _hookConfiguration = new();
    private readonly ClaudeHookConfiguration _claudeHookConfiguration = new();
    private readonly ReplayGuard _replayGuard = new();
    private readonly byte[] _pairingSecret;
    private readonly Func<X509Certificate2> _loadPhoneIdentity;
    private X509Certificate2? _phoneIdentity;
    private string? _phoneFingerprint;
    private readonly bool _loopbackOnly;
    private readonly TaskCatalog _catalog;
    private HookTcpServer? _hookServer;
    private LanBridgeServer? _lanServer;
    private CancellationTokenSource? _linkedCancellation;
    private Task? _eventTask;
    private Task? _pollTask;
    private Task? _usageTask;
    private UsageSnapshot? _usage;
    private List<string> _enabledSources = [];
    private HermesUsageSnapshot? _hermesUsage;
    private readonly HermesAccessTokenStore _hermesTokenStore;
    private readonly NativeHermesUsageClient _nativeHermes = new();
    private Task? _nativeHermesTask;
    private int _hermesSourceRevision;
    private bool _hasHermesAccessToken;
    private string _nativeHermesStatus = "未配置原生 HTTP 统计";
    private DateTimeOffset? _lastHookAt;
    private string _serviceStatus = "正在启动";
    private string? _lastError;
    private int _phoneCount;
    private string _selectedAddress;
    private List<NetworkAddressOption> _networks;

    public BridgeRuntime() : this(BridgeSettings.Load(), new PairingSecretStore().LoadOrCreate(), loadPhoneIdentity: PhoneTlsIdentity.LoadOrCreate) { }

    internal BridgeRuntime(BridgeSettings settings, byte[] pairingSecret, bool loopbackOnly = false,
        HermesAccessTokenStore? hermesTokenStore = null, Func<X509Certificate2>? loadPhoneIdentity = null)
    {
        if (pairingSecret.Length != 32) throw new ArgumentException("Phone pairing requires a 32-byte key.", nameof(pairingSecret));
        _loadPhoneIdentity = loadPhoneIdentity ?? (loopbackOnly ? PhoneTlsIdentity.Create : PhoneTlsIdentity.LoadOrCreate);
        Settings = settings;
        _hermesTokenStore = hermesTokenStore ?? new();
        if (!string.IsNullOrEmpty(settings.HermesServiceUrl))
        {
            _nativeHermesStatus = "已配置 · 等待读取原生统计";
            try { _hasHermesAccessToken = _hermesTokenStore.Load(settings.HermesServiceUrl, settings.HermesProfile) is { Length: > 0 };
                _hermesSignedInUsername = _hermesTokenStore.LoadSession(settings.HermesServiceUrl, settings.HermesProfile)?.Username; }
            catch (Exception e) when (HermesSettingsError(e)) { _nativeHermesStatus = "访问令牌不可读取，请重新录入。"; }
        }
        _log = new DailyFileLog(settings.LogDirectory);
        _usageLoader = new(_modelPrices);
        _networks = NetworkAddresses.Available();
        _selectedAddress = _networks.FirstOrDefault(value => value.Address == Settings.SelectedNetworkAddress)?.Address
            ?? _networks.FirstOrDefault()?.Address ?? "127.0.0.1";
        Settings.SelectedNetworkAddress = _selectedAddress;
        _pairingSecret = pairingSecret;
        _loopbackOnly = loopbackOnly;
        _hermesSetup = new(_pairingSecret);
        _hermesSetup.UpgradeInstalled();
        _log.Write("INFO", _hermesSetup.UpdateStatus);
        _catalog = new(_persistence.Load());
        _catalog.ApplyTitles(_titleReader.Load());
        // Browser leases cannot survive a process restart without fresh browser evidence.
        ClearActiveWebTasks();
        _webMonitor = new(payload => _events.Writer.TryWrite(new WebHookEvent(
            JsonSerializer.Deserialize<CodexHookPayload>(JsonSerializer.Serialize(payload), WireJson.Options)!)),
            Settings.WebMonitoringEnabled);
        _webMonitor.StateChanged += () => _events.Writer.TryWrite(new WebStatusChangedEvent());
        _enabledSources = DetectEnabledSources();
        State = CreateState();
    }

    public BridgeSettings Settings { get; }
    public BridgeViewState State { get; private set; }
    public event Action? StateChanged;


    public Task StartAsync(CancellationToken cancellationToken) => StartAsync(cancellationToken, startWebListener: true);

    internal async Task StartAsync(CancellationToken cancellationToken, bool startWebListener)
    {
        _linkedCancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        var token = _linkedCancellation.Token;
        _eventTask = EventLoop(token);
        try
        {
            _hookServer = new HookTcpServer(
                envelope => _events.Writer.WriteAsync(new HookEvent(envelope), token).AsTask(), _log);
            _hookServer.Start();
            _phoneIdentity = _loadPhoneIdentity();
            _lanServer = new(
                _phoneIdentity,
                _pairingSecret,
                SnapshotText,
                text => _events.Writer.WriteAsync(new ControlEvent(text), token).AsTask(),
                count => _events.Writer.TryWrite(new PhoneCountEvent(count)),
                _log,
                _hermesSetup.Token,
                heartbeat => _events.Writer.TryWrite(new HermesHeartbeatEvent(heartbeat)),
                _loopbackOnly);
            await _lanServer.StartAsync(token);
            _phoneFingerprint = PhoneTlsIdentity.Fingerprint(_phoneIdentity);
            _serviceStatus = "局域网服务运行中";
            _log.Write("INFO", "Bridge 服务已启动。");
        }
        catch (Exception error)
        {
            _serviceStatus = "服务启动失败";
            _lastError = error.Message;
            _log.Write("ERROR", error.ToString());
        }
        // A legacy web helper occupying 49363 must not take down Hermes or LAN hosting.
        if (startWebListener)
        {
            try { await _webMonitor.StartAsync(token); }
            catch (Exception error) when (error is not OperationCanceledException)
            { _log.Write("ERROR", $"ChatGPT 网页监听启动失败：{error.GetType().Name}"); }
        }
        PublishState();
        _pollTask = PollLoop(token);
        _usageTask = UsageLoop(token);
        _nativeHermesTask = NativeHermesLoop(token);
    }

    public bool HasHermesAccessToken => _hasHermesAccessToken;
    public string NativeHermesStatus => _nativeHermesStatus + (Settings.HermesServiceUrl?.StartsWith("http://", StringComparison.OrdinalIgnoreCase) == true
        ? " · 警告：HTTP 明文传输账号和会话，请仅用于可信网络/VPN；建议 HTTPS" : "");
    public bool TrySetHermesSource(string url, string? profile, string newToken, bool clearToken, out string? error, bool allowAnonymous = false)
    {
        lock (Settings)
        {
            var oldUrl = Settings.HermesServiceUrl;
            var oldProfile = Settings.HermesProfile;
            var oldAnonymous = Settings.HermesAllowAnonymous;
            byte[]? oldProtected = null;
            var tokenTouched = false;
            try
            {
                var canonical = string.IsNullOrWhiteSpace(url) ? null : NativeHermesUsageClient.ValidateBaseUrl(url.Trim()).AbsoluteUri;
                profile = canonical is null ? null : NativeHermesUsageClient.ValidateProfile(profile);
                NativeHermesUsageClient.ValidateToken(newToken);
                var sameSource = canonical == oldUrl && profile == oldProfile;
                if (canonical is not null && !allowAnonymous && (clearToken || newToken.Length == 0 && (!sameSource || !_hasHermesAccessToken)))
                    throw new ArgumentException("新来源需要访问令牌，或明确选择匿名访问。");
                oldProtected = _hermesTokenStore.ReadProtected();
                if (clearToken || !sameSource || newToken.Length > 0)
                {
                    tokenTouched = true;
                    _hermesTokenStore.Save(canonical ?? oldUrl ?? "", clearToken || canonical is null ? "" : newToken, profile);
                }
                Settings.HermesServiceUrl = canonical;
                Settings.HermesProfile = profile;
                Settings.HermesAllowAnonymous = canonical is not null && allowAnonymous;
                Settings.Save();
                var confirmed = BridgeSettings.Load();
                if (confirmed.HermesServiceUrl != canonical || confirmed.HermesProfile != profile ||
                    confirmed.HermesAllowAnonymous != Settings.HermesAllowAnonymous)
                    throw new IOException("Hermes 连接设置保存后校验失败。");
                _hasHermesAccessToken = canonical is not null && _hermesTokenStore.Load(canonical, profile) is { Length: > 0 };
                _hermesSignedInUsername = canonical is null ? null : _hermesTokenStore.LoadSession(canonical, profile)?.Username;
                _hermesRequiresLogin = false;
                ++_hermesAuthEpoch;
                var revision = Interlocked.Increment(ref _hermesSourceRevision);
                _hermesUsage = null;
                _nativeHermesStatus = canonical is null ? "未配置原生 HTTP 统计" : "设置已保存 · 等待下次原生读取（间隔至少 60 秒）";
                _events.Writer.TryWrite(new HermesSourceChangedEvent(revision));
                error = null;
                return true;
            }
            catch (Exception e) when (HermesSettingsError(e))
            {
                Settings.HermesServiceUrl = oldUrl;
                Settings.HermesProfile = oldProfile;
                Settings.HermesAllowAnonymous = oldAnonymous;
                try { if (tokenTouched) _hermesTokenStore.RestoreProtected(oldProtected); Settings.Save(); }
                catch (Exception rollback) when (HermesSettingsError(rollback)) { }
                error = "Hermes 连接未保存；请检查地址格式、令牌或设置文件权限。新服务/Profile 必须录入令牌或明确允许匿名访问。";
                return false;
            }
        }
    }
    private static bool HermesSettingsError(Exception e) => e is IOException or UnauthorizedAccessException or ArgumentException or
        System.Security.Cryptography.CryptographicException or System.Security.SecurityException or NotSupportedException;

    public void SetWebMonitorEnabled(bool enabled) => _events.Writer.TryWrite(new WebEnabledEvent(enabled));

    private static CodexHookPayload WebOffline(string id) => JsonSerializer.Deserialize<CodexHookPayload>(
        JsonSerializer.Serialize(new { cwd = @"C:\AgentPager\ChatGPT", hook_event_name = "SessionOffline", session_id = id, source = "app" }),
        WireJson.Options)!;

    private bool ClearActiveWebTasks()
    {
        var changed = false;
        foreach (var task in _catalog.Projection().Tasks.Where(task =>
            CodexHookPayload.IsChatGPTWebID(task.Id) && task.Lifecycle is
                AgentLifecycle.Starting or AgentLifecycle.Running or AgentLifecycle.WaitingApproval or AgentLifecycle.WaitingAnswer))
            changed = _catalog.Accept(WebOffline(task.Id)) || changed;
        return changed;
    }

    public void InstallHermesPlugin()
    {
        try
        {
            _hermesSetup.Install();
            _lastError = null;
            _log.Write("INFO", "已写入 Hermes Desktop 状态插件，需在 Hermes 中启用。");
        }
        catch (Exception error)
        {
            _lastError = $"安装 Hermes 插件失败：{error.Message}";
            _log.Write("ERROR", _lastError);
        }
        _events.Writer.TryWrite(new ConfigurationChangedEvent());
        PublishState();
    }

    public void InstallHook()
    {
        try
        {
            var result = _hookConfiguration.Install(Environment.ProcessPath!);
            _log.Write("INFO", result.Changed ? "Codex Hook 已安装。" : "Codex Hook 已是最新状态。");
            _lastError = null;
        }
        catch (Exception error)
        {
            _lastError = $"安装 Hook 失败：{error.Message}";
            _log.Write("ERROR", _lastError);
        }
        _events.Writer.TryWrite(new ConfigurationChangedEvent());
        PublishState();
    }

    public void UninstallHook()
    {
        try
        {
            _ = _hookConfiguration.Uninstall();
            _lastError = null;
            _log.Write("INFO", "Codex Hook 已移除。");
        }
        catch (Exception error)
        {
            _lastError = $"卸载 Hook 失败：{error.Message}";
            _log.Write("ERROR", _lastError);
        }
        _events.Writer.TryWrite(new ConfigurationChangedEvent());
        PublishState();
    }

    public void InstallClaudeHook()
    {
        try
        {
            var result = _claudeHookConfiguration.Install(Environment.ProcessPath!);
            _log.Write("INFO", result.Changed ? "Claude Code Hook 已安装。" : "Claude Code Hook 已是最新状态。");
            _lastError = null;
        }
        catch (Exception error)
        {
            _lastError = $"安装 Claude Code Hook 失败：{error.Message}";
            _log.Write("ERROR", _lastError);
        }
        _events.Writer.TryWrite(new ConfigurationChangedEvent());
        PublishState();
    }

    public void UninstallClaudeHook()
    {
        try
        {
            _ = _claudeHookConfiguration.Uninstall();
            _lastError = null;
            _log.Write("INFO", "Claude Code Hook 已移除。");
        }
        catch (Exception error)
        {
            _lastError = $"卸载 Claude Code Hook 失败：{error.Message}";
            _log.Write("ERROR", _lastError);
        }
        _events.Writer.TryWrite(new ConfigurationChangedEvent());
        PublishState();
    }

    public void SelectAddress(string address)
    {
        if (_networks.All(value => value.Address != address)) return;
        _selectedAddress = address;
        Settings.SelectedNetworkAddress = address;
        Settings.Save();
        PublishState();
    }

    public string ActiveLogDirectory => _log.ActiveDirectory;
    public string? LogDirectoryError => _log.LastError;

    public bool TrySetLogDirectory(string? directory, out string? error)
    {
        var changed = _log.TrySetDirectory(directory, value =>
        {
            lock (Settings)
            {
                var previous = Settings.LogDirectory;
                Settings.LogDirectory = value;
                try { Settings.Save(); }
                catch
                {
                    Settings.LogDirectory = previous;
                    throw;
                }
            }
        }, out error);
        if (changed) _log.Write("INFO", "日志目录设置已更新；旧日志保留原位。");
        PublishState();
        return changed;
    }

    public StartupStatus SetLaunchAtLogin(bool enabled)
    {
        var actual = StartupRegistration.SetEnabled(enabled);
        if (actual.Enabled is { } registered)
        {
            Settings.LaunchAtLogin = registered;
            try { Settings.Save(); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException or System.Security.SecurityException)
            {
                actual = actual with { Message = $"{actual.Message}；保存偏好失败：{error.Message}" };
            }
        }
        PublishState();
        return actual;
    }

    public void RefreshNetworks()
    {
        _networks = NetworkAddresses.Available();
        if (_networks.All(value => value.Address != _selectedAddress))
            _selectedAddress = _networks.FirstOrDefault()?.Address ?? "127.0.0.1";
        Settings.SelectedNetworkAddress = _selectedAddress;
        Settings.Save();
        PublishState();
    }

    private async Task EventLoop(CancellationToken cancellationToken)
    {
        await foreach (var value in _events.Reader.ReadAllAsync(cancellationToken))
        {
            try
            {
                var changed = false;
                switch (value)
                {
                    case HookEvent hook:
                        _lastHookAt = DateTimeOffset.Now;
                        changed = hook.Envelope switch
                        {
                            HookEnvelope.Codex codex when !codex.Hook.IsChatGPTWeb || _webMonitor.State.Enabled => HandleCodexHook(codex.Hook),
                            HookEnvelope.Claude claude => _catalog.Accept(claude.Hook),
                            _ => false,
                        };
                        break;
                    case WebHookEvent web:
                        changed = _catalog.Accept(web.Hook);
                        break;
                    case WebEnabledEvent web:
                        _webMonitor.SetEnabled(web.Enabled);
                        if (!web.Enabled) changed = ClearActiveWebTasks();
                        Settings.WebMonitoringEnabled = web.Enabled;
                        Settings.Save();
                        PublishState();
                        break;
                    case WebStatusChangedEvent:
                        PublishState();
                        break;
                    case ConfigurationChangedEvent:
                        break; // Source detection below also covers task-independent configuration changes.
                    case RolloutEvent rollout:
                        changed = _catalog.Accept(rollout.Signals);
                        break;
                    case ControlEvent control:
                        changed = await HandleControl(control.Text);
                        break;
                    case PhoneCountEvent count:
                        _phoneCount = count.Count;
                        changed = true;
                        break;
                    case UsageEvent usage:
                        changed = !SameUsage(_usage, usage.Usage);
                        _usage = usage.Usage;
                        break;
                    case HermesSourceChangedEvent source:
                        lock (Settings)
                        {
                            if (source.Revision != _hermesSourceRevision) break;
                            _hermesUsage = null;
                            changed = true;
                        }
                        break;
                    case NativeHermesEvent native:
                        lock (Settings)
                        {
                            if (native.Revision != _hermesSourceRevision || string.IsNullOrEmpty(Settings.HermesServiceUrl)) break;
                            _hermesUsage = native.Usage;
                            _nativeHermesStatus = native.Status;
                            changed = true;
                        }
                        break;
                    case HermesHeartbeatEvent hermes:
                        var received = _hermesStatus.LastReceivedAt;
                        _hermesStatus.Accept(hermes.Heartbeat, "本机连接");
                        var heartbeatNow = DateTimeOffset.UtcNow;
                        if (_hermesStatus.Snapshot(heartbeatNow) is { } observed)
                            changed = _catalog.AcceptHermesStatus(observed, heartbeatNow);
                        if (!changed && received != _hermesStatus.LastReceivedAt) PublishState();
                        break;
                    case MaintenanceEvent:
                        changed = _catalog.Maintain();
                        var now = DateTimeOffset.UtcNow;
                        if (_hermesUsage is { IsPartial: false } cachedHistory && now - cachedHistory.CapturedAt >= TimeSpan.FromMinutes(3))
                        { _hermesUsage = cachedHistory with { IsPartial = true }; changed = true; }
                        var prior = _hermesStatus.LastReceivedAt;
                        _hermesStatus.Read(now);
                        if (_hermesStatus.Snapshot(now) is { } hermesSnapshot)
                            changed = _catalog.AcceptHermesStatus(hermesSnapshot, now) || changed;
                        changed = _catalog.ApplyTitles(_titleReader.Load()) || changed;
                        if (!changed && (prior != _hermesStatus.LastReceivedAt ||
                            State.HermesPluginInstalled != _hermesSetup.IsInstalled)) PublishState();
                        break;
                }
                var sources = DetectEnabledSources();
                if (!_enabledSources.SequenceEqual(sources)) { _enabledSources = sources; changed = true; }
                if (!changed) continue;
                SaveAndBroadcast();
            }
            catch (Exception error)
            {
                _lastError = error.Message;
                _log.Write("ERROR", error.ToString());
                PublishState();
            }
        }
    }

    private bool HandleCodexHook(CodexHookPayload hook)
    {
        _rollout.Include(hook);
        return _catalog.Accept(hook);
    }

    private async Task<bool> HandleControl(string text)
    {
        SignedControlEnvelope? request;
        try { request = JsonSerializer.Deserialize<SignedControlEnvelope>(text, WireJson.Options); }
        catch (JsonException) { return false; }
        if (request is null) return false;
        ControlAckPayload acknowledgment;
        try
        {
            _replayGuard.Validate(request, _pairingSecret);
            acknowledgment = _catalog.Perform(request.MessageId, request.Payload,
                _hookServer ?? throw new InvalidOperationException("Hook 通道尚未就绪"));
        }
        catch (ProtocolException)
        {
            acknowledgment = new(request.MessageId, ControlResult.Rejected, "签名或序号无效");
        }
        var envelope = MessageEnvelope<ControlAckPayload>.Create("control.ack", acknowledgment);
        if (_lanServer is not null)
            await _lanServer.BroadcastAsync(JsonSerializer.Serialize(envelope, WireJson.Options));
        return acknowledgment.Result == ControlResult.Accepted;
    }

    private async Task PollLoop(CancellationToken cancellationToken)
    {
        var maintenanceCounter = 0;
        while (!cancellationToken.IsCancellationRequested)
        {
            try
            {
                await Task.Delay(750, cancellationToken);
                var signals = _rollout.Observe();
                if (signals.Count > 0) await _events.Writer.WriteAsync(new RolloutEvent(signals), cancellationToken);
                if (++maintenanceCounter >= 4)
                {
                    maintenanceCounter = 0;
                    await _events.Writer.WriteAsync(new MaintenanceEvent(), cancellationToken);
                }
            }
            catch (OperationCanceledException) { break; }
        }
    }

    private async Task UsageLoop(CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested)
        {
            try
            {
                var usage = await Task.Run(() => _usageLoader.Load(cancellationToken: cancellationToken), cancellationToken);
                await _events.Writer.WriteAsync(new UsageEvent(usage), cancellationToken);
                // Publish offline/cached data first; network refresh never delays the initial snapshot.
                if (!_loopbackOnly && await _modelPrices.RefreshAsync(cancellationToken: cancellationToken))
                {
                    _usageLoader.InvalidatePrices();
                    usage = await Task.Run(() => _usageLoader.Load(cancellationToken: cancellationToken), cancellationToken);
                    await _events.Writer.WriteAsync(new UsageEvent(usage), cancellationToken);
                }
            }
            catch (OperationCanceledException) { break; }
            catch (Exception error)
            {
                _log.Write("ERROR", $"读取 Codex 额度失败：{error}");
            }

            try { await Task.Delay(TimeSpan.FromSeconds(20), cancellationToken); }
            catch (OperationCanceledException) { break; }
        }
    }

    private async Task NativeHermesLoop(CancellationToken cancellationToken)
    {
        var nextAttempt = DateTimeOffset.MinValue;
        while (!cancellationToken.IsCancellationRequested)
        {
            string? url; string? profile; int revision;
            lock (Settings) { url = Settings.HermesServiceUrl; profile = Settings.HermesProfile; revision = _hermesSourceRevision; }
            if (url is not null && DateTimeOffset.UtcNow >= nextAttempt)
            {
                nextAttempt = DateTimeOffset.UtcNow.AddSeconds(NativeHermesUsageClient.MinimumPollSeconds);
                try
                {
                    var accessToken = await GetHermesAccessTokenAsync(url, profile, revision, cancellationToken);
                    var usage = await _nativeHermes.ReadAsync(url, profile, accessToken, cancellationToken);
                    await _events.Writer.WriteAsync(new NativeHermesEvent(revision, usage,
                        $"最近成功读取：{usage.CapturedAt.ToLocalTime():yyyy-MM-dd HH:mm:ss}" + (usage.IsPartial ? " · 部分范围不可用" : " · 原生统计已连接")), cancellationToken);
                }
                catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { break; }
                catch (Exception e) when (HermesAuthError(e))
                {
                    if (e is HermesAuthenticationException { RequiresLogin: true })
                        lock (Settings) { if (revision == _hermesSourceRevision) MarkHermesRelogin(); }
                    await _events.Writer.WriteAsync(new NativeHermesEvent(revision, null,
                        "原生统计读取失败；请检查 URL、端口、Profile 和登录状态/访问令牌。不会回退到其他来源。"), cancellationToken);
                }
            }
            try { await Task.Delay(1000, cancellationToken); }
            catch (OperationCanceledException) { break; }
        }
    }

    private static bool SameUsage(UsageSnapshot? first, UsageSnapshot? second) =>
        ReferenceEquals(first, second) || first is not null && second is not null &&
        first.CapturedAt == second.CapturedAt && first.PlanType == second.PlanType && first.LimitID == second.LimitID &&
        first.IsPartial == second.IsPartial && first.Windows.SequenceEqual(second.Windows) &&
        first.DailyUsage.SequenceEqual(second.DailyUsage);

    private void SaveAndBroadcast()
    {
        var projection = _catalog.Projection();
        try { _persistence.Save(projection.Tasks); }
        catch (IOException error)
        {
            _lastError = $"保存任务状态失败：{error.Message}";
            _log.Write("ERROR", _lastError);
        }
        PublishState();
        if (_lanServer is not null) _ = _lanServer.BroadcastAsync(SnapshotText());
    }

    private string PairingText() => _phoneFingerprint is not { } fingerprint ? "" :
        JsonSerializer.Serialize(new PairingPayload(
            2,
            $"agentgrid-windows-{Environment.MachineName}",
            _loopbackOnly ? "127.0.0.1" : _selectedAddress,
            LanBridgeServer.PhonePort,
            Convert.ToBase64String(_pairingSecret),
            fingerprint), WireJson.Options);

    private string SnapshotText()
    {
        var projection = _catalog.Projection();
        var tasks = projection.Tasks.Select(task => task with
        {
            LatestStep = ToolStepSanitizer.Sanitize(task.LatestStep),
            Subagents = task.Subagents.Select(subagent =>
                subagent with { LatestStep = ToolStepSanitizer.Sanitize(subagent.LatestStep) }).ToList(),
        }).ToList();
        var payload = new StateSnapshotPayload(tasks, _usage, projection.FocusedTaskID, projection.PendingRequests)
        { HermesUsage = _hermesUsage, EnabledSources = _enabledSources };
        return JsonSerializer.Serialize(MessageEnvelope<StateSnapshotPayload>.Create("state.snapshot", payload), WireJson.Options);
    }

    private List<string> DetectEnabledSources()
    {
        var sources = new List<string>();
        // Rollout monitoring is automatic even without hooks. Cached tasks, CLI installation,
        // and the independent ChatGPT web toggle are not evidence of a Codex data source.
        if (_hookConfiguration.IsInstalled() || Directory.Exists(Path.Combine(CodexPaths.Home, "sessions")) ||
            Directory.Exists(Path.Combine(CodexPaths.Home, "archived_sessions"))) sources.Add("codex");
        if (_claudeHookConfiguration.IsInstalled()) sources.Add("claude");
        // Disconnection is not an uninstall; never derive enablement from heartbeat freshness.
        if (_hermesSetup.IsInstalled || !string.IsNullOrEmpty(Settings.HermesServiceUrl)) sources.Add("hermes");
        return sources;
    }

    private BridgeViewState CreateState() => new(
        _serviceStatus,
        _phoneCount,
        _hookConfiguration.IsInstalled(),
        _claudeHookConfiguration.IsInstalled(),
        _lastHookAt,
        _lastError,
        PairingText(),
        _selectedAddress,
        _networks,
        _catalog.Projection().Tasks.Count,
        _hermesSetup.IsInstalled,
        _hermesSetup.PluginPath,
        _hermesSetup.UpdateStatus,
        _hermesStatus.Lifecycle(DateTimeOffset.UtcNow),
        _hermesStatus.LastReceivedAt,
        _hermesStatus.Transport,
        _webMonitor.State);

    private void PublishState()
    {
        State = CreateState();
        StateChanged?.Invoke();
    }

    public async ValueTask DisposeAsync()
    {
        await _webMonitor.DisposeAsync();
        _linkedCancellation?.Cancel();
        if (_pollTask is not null) try { await _pollTask; } catch (OperationCanceledException) { }
        if (_usageTask is not null) try { await _usageTask; } catch (OperationCanceledException) { }
        if (_nativeHermesTask is not null) try { await _nativeHermesTask; } catch (OperationCanceledException) { }
        _nativeHermes.Dispose();
        _hermesAuth.Dispose();
        if (_hookServer is not null) await _hookServer.DisposeAsync();
        if (_lanServer is not null) await _lanServer.DisposeAsync();
        _phoneIdentity?.Dispose();
        _events.Writer.TryComplete();
        if (_eventTask is not null) try { await _eventTask; } catch (OperationCanceledException) { }
        _linkedCancellation?.Dispose();
    }
}
