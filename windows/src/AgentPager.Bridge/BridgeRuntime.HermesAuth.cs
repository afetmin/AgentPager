using AgentPager.Core;

namespace AgentPager.Bridge;

public sealed partial class BridgeRuntime
{
    private readonly NativeHermesAuthClient _hermesAuth = new();
    private readonly SemaphoreSlim _hermesRefresh = new(1, 1);
    private int _hermesAuthEpoch;
    private bool _hermesRequiresLogin;
    private string? _hermesSignedInUsername;
    public string? HermesSignedInUsername => Volatile.Read(ref _hermesSignedInUsername);
    internal int HermesSourceRevision => Volatile.Read(ref _hermesSourceRevision);
    internal string HermesUsageStatus
    {
        get
        {
            return HasHermesAccessToken && Uri.TryCreate(Settings.HermesServiceUrl, UriKind.Absolute, out var source) &&
                !HermesCredentialTransport.AllowsCredentials(source) ? HermesCredentialTransport.HttpsRequiredMessage : _nativeHermesStatus;
        }
    }

    private static bool HermesAuthError(Exception e) => HermesSettingsError(e) || e is System.Net.Http.HttpRequestException or
        OperationCanceledException or System.Text.Json.JsonException or FormatException or InvalidOperationException or KeyNotFoundException;

    public async Task<(bool Ok, string? Error)> LoginHermesAsync(string url, string? profile, string username, string password, CancellationToken ct = default)
    {
        try
        {
            var canonical = NativeHermesUsageClient.ValidateBaseUrl(url.Trim()).AbsoluteUri;
            profile = NativeHermesUsageClient.ValidateProfile(profile);
            int epoch;
            lock (Settings) epoch = ++_hermesAuthEpoch;
            var session = await _hermesAuth.LoginAsync(canonical, username, password, ct).ConfigureAwait(false);
            lock (Settings)
            {
                ct.ThrowIfCancellationRequested();
                if (epoch != _hermesAuthEpoch) return (false, "来源或登录状态已变更，本次登录结果已丢弃。");
                var oldUrl = Settings.HermesServiceUrl;
                var oldProfile = Settings.HermesProfile;
                var oldAnonymous = Settings.HermesAllowAnonymous;
                var oldProtected = _hermesTokenStore.ReadProtected();
                try
                {
                    _hermesTokenStore.SaveSession(canonical, profile, session);
                    Settings.HermesServiceUrl = canonical;
                    Settings.HermesProfile = profile;
                    Settings.HermesAllowAnonymous = false;
                    Settings.Save();
                    var saved = BridgeSettings.Load();
                    if (saved.HermesServiceUrl != canonical || saved.HermesProfile != profile || saved.HermesAllowAnonymous)
                        throw new IOException("会话设置保存后校验失败。");
                }
                catch
                {
                    Settings.HermesServiceUrl = oldUrl;
                    Settings.HermesProfile = oldProfile;
                    Settings.HermesAllowAnonymous = oldAnonymous;
                    try { _hermesTokenStore.RestoreProtected(oldProtected); Settings.Save(); }
                    catch (Exception rollback) when (HermesAuthError(rollback)) { }
                    throw;
                }
                _hermesSignedInUsername = session.Username;
                _hasHermesAccessToken = true;
                _hermesRequiresLogin = false;
                ResetHermesAccountState("已登录 Hermes 账号 · 等待原生统计读取");
            }
            return (true, null);
        }
        catch (OperationCanceledException) { return (false, ct.IsCancellationRequested ? "登录已取消。" : "登录超时；请检查网络后手动重试。"); }
        catch (HermesAuthenticationException e) { return (false, e.Message); }
        catch (Exception e) when (HermesAuthError(e))
        { return (false, "Hermes 登录失败；请检查服务地址、网络或安全存储权限。密码不会保存，也不会自动重试。"); }
    }

    // Local sign-out only: the synchronous UI API never sends credentials or blocks on a server.
    // It does not claim to revoke the remote account's other sessions.
    public bool LogoutHermes(out string? error)
    {
        lock (Settings)
        {
            ++_hermesAuthEpoch; // Fence pending login/refresh even if local deletion fails.
            _hermesRequiresLogin = true;
            _hermesSignedInUsername = null;
            _hasHermesAccessToken = false;
            ResetHermesAccountState("已退出本机 Hermes 账号 · 请重新登录");
            try
            {
                _hermesTokenStore.RestoreProtected(null);
                if (_hermesTokenStore.ReadProtected() is not null) throw new IOException("会话删除失败。");
                error = null;
                return true;
            }
            catch (Exception e) when (HermesAuthError(e))
            { error = "本机已停止使用此会话，但无法删除安全存储；请检查文件权限并再次退出。"; return false; }
        }
    }

    private void ResetHermesAccountState(string status)
    {
        var revision = Interlocked.Increment(ref _hermesSourceRevision);
        _hermesUsage = null;
        _nativeHermesStatus = status;
        _events.Writer.TryWrite(new HermesSourceChangedEvent(revision));
    }

    internal async Task<string> GetHermesAccessTokenAsync(string url, string? profile, int revision, CancellationToken ct)
    {
        await _hermesRefresh.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            HermesAccountSession? session;
            int epoch;
            lock (Settings)
            {
                RequireCurrent();
                epoch = _hermesAuthEpoch;
                if (_hermesRequiresLogin) throw new HermesAuthenticationException("会话已失效，请重新登录。", true);
                session = _hermesTokenStore.LoadSession(url, profile);
                if (session is null)
                {
                    var manual = _hermesTokenStore.Load(url, profile) ?? "";
                    if (manual.Length == 0 && !Settings.HermesAllowAnonymous) throw new HermesAuthenticationException("请先登录 Hermes 账号或配置访问令牌。", true);
                    if (manual.Length != 0) HermesCredentialTransport.RequireSecure(NativeHermesUsageClient.ValidateBaseUrl(url));
                    return manual;
                }
                HermesCredentialTransport.RequireSecure(NativeHermesUsageClient.ValidateBaseUrl(url));
                if (session.ExpiresAt > DateTimeOffset.UtcNow.AddSeconds(90)) return session.AccessToken;
            }
            HermesAccountSession rotated;
            try { rotated = await _hermesAuth.RefreshAsync(url, session, ct).ConfigureAwait(false); }
            catch (HermesAuthenticationException e) when (e.RequiresLogin)
            {
                lock (Settings)
                {
                    if (revision == _hermesSourceRevision && epoch == _hermesAuthEpoch) MarkHermesRelogin();
                }
                throw;
            }
            lock (Settings)
            {
                ct.ThrowIfCancellationRequested();
                RequireCurrent();
                if (epoch != _hermesAuthEpoch) throw new HermesAuthenticationException("登录状态已变更，请重新读取。");
                try { _hermesTokenStore.SaveSession(url, profile, rotated); }
                catch (Exception e) when (HermesAuthError(e))
                {
                    MarkHermesRelogin(); // The rotated refresh token must not be used unless durable.
                    throw new HermesAuthenticationException("刷新会话无法安全保存，请重新登录。", true);
                }
                _hermesSignedInUsername = rotated.Username;
                return rotated.AccessToken;
            }
        }
        finally { _hermesRefresh.Release(); }

        void RequireCurrent()
        {
            if (revision != _hermesSourceRevision || url != Settings.HermesServiceUrl || profile != Settings.HermesProfile)
                throw new HermesAuthenticationException("Hermes 来源已变更，旧会话结果已丢弃。");
        }
    }

    private void MarkHermesRelogin()
    {
        _hermesRequiresLogin = true;
        _hermesSignedInUsername = null;
        _hasHermesAccessToken = false;
        ResetHermesAccountState("Hermes 会话失效 · 请重新登录（不会重用密码）");
    }
}
