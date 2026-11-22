using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text.Json;
using Microsoft.Win32;
using AgentPager.Core;

namespace AgentPager.Bridge;

public sealed record NetworkAddressOption(string ID, string Label, string Address);

public static class NetworkAddresses
{
    public static List<NetworkAddressOption> Available()
    {
        var result = new List<(NetworkAddressOption Option, bool Gateway)>();
        foreach (var adapter in NetworkInterface.GetAllNetworkInterfaces())
        {
            if (adapter.OperationalStatus != OperationalStatus.Up ||
                adapter.NetworkInterfaceType is NetworkInterfaceType.Loopback or NetworkInterfaceType.Tunnel)
                continue;
            var properties = adapter.GetIPProperties();
            var hasGateway = properties.GatewayAddresses.Any(value =>
                value.Address.AddressFamily == AddressFamily.InterNetwork &&
                !value.Address.Equals(IPAddress.Any));
            foreach (var unicast in properties.UnicastAddresses)
            {
                if (unicast.Address.AddressFamily != AddressFamily.InterNetwork ||
                    IPAddress.IsLoopback(unicast.Address)) continue;
                result.Add((new(adapter.Id, $"{adapter.Name} · {unicast.Address}", unicast.Address.ToString()), hasGateway));
            }
        }
        return result.OrderByDescending(value => value.Gateway).ThenBy(value => value.Option.Label)
            .Select(value => value.Option).ToList();
    }
}

public sealed class BridgeSettings
{
    public string? SelectedNetworkAddress { get; set; }
    public bool LaunchAtLogin { get; set; } = true;
    public bool HasCompletedFirstRun { get; set; }
    public bool WebMonitoringEnabled { get; set; } = true;
    public string? HermesServiceUrl { get; set; }
    public string? HermesProfile { get; set; }
    public bool HermesAllowAnonymous { get; set; }
    [System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)]
    public string? LogDirectory { get; set; }

    public static BridgeSettings Load(string? filePath = null)
    {
        try
        {
            var path = filePath ?? AgentPagerPaths.SettingsFile;
            if (File.Exists(path))
                return JsonSerializer.Deserialize<BridgeSettings>(File.ReadAllText(path)) ?? new();
        }
        catch (Exception error) when (error is IOException or JsonException or UnauthorizedAccessException or System.Security.SecurityException) { }
        return new();
    }

    // Saving another preference must never re-enable an entry disabled in Windows Startup Apps.
    public void Save(string? filePath = null)
    {
        lock (this)
        {
            var path = filePath ?? AgentPagerPaths.SettingsFile;
            Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
            var temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
            try
            {
                File.WriteAllText(temporary,
                    JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true }));
                File.Move(temporary, path, overwrite: true);
            }
            finally
            {
                try { File.Delete(temporary); }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
            }
        }
    }
}

public sealed record StartupStatus(bool? Enabled, string Message);

public static partial class StartupRegistration
{
    private const string KeyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ApprovalPath = @"Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run";
    private const string ValueName = "AgentPager";

    internal static string Command(string executable) => $"\"{executable}\" --background";

    // StartupApproved is also checked: a Run value alone may be disabled in Startup Apps.
    internal static StartupStatus Evaluate(string? command, object? approval, string executable)
    {
        if (command is null) return new(false, "未启用 · 当前用户未注册登录启动");
        if (!string.Equals(command, Command(executable), StringComparison.OrdinalIgnoreCase))
            return new(false, "未启用当前程序 · 启动项指向旧路径；勾选可修复");
        if (approval is null) return new(true, "已启用 · 当前用户登录后在后台启动");
        if (approval is not byte[] bytes || bytes.Length < 4)
            return new(null, "无法确认 Windows 启动许可状态；请检查系统“启动应用”");
        return System.Buffers.Binary.BinaryPrimitives.ReadUInt32LittleEndian(bytes) switch
        {
            0 or 2 or 6 => new(true, "已启用 · 当前用户登录后在后台启动"),
            3 or 7 => new(false, "已被 Windows 禁用 · 勾选可重新启用"),
            _ => new(null, "无法确认 Windows 启动许可状态；请检查系统“启动应用”"),
        };
    }

    public static StartupStatus ReadStatus()
    {
        if (!OperatingSystem.IsWindows()) return new(null, "登录启动只支持 Windows");
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(KeyPath);
            using var approval = Registry.CurrentUser.OpenSubKey(ApprovalPath);
            return Evaluate(key?.GetValue(ValueName) as string, approval?.GetValue(ValueName),
                Environment.ProcessPath ?? throw new IOException("无法确定当前程序路径"));
        }
        catch (Exception error) when (IsRegistrationError(error))
        {
            return new(null, $"无法读取登录启动状态：{error.Message}");
        }
    }

    public static StartupStatus SetEnabled(bool enabled) => Change(enabled,
        value => { if (value) Enable(); else Disable(); }, ReadStatus);

    internal static StartupStatus Change(bool enabled, Action<bool> write, Func<StartupStatus> read)
    {
        try
        {
            write(enabled);
            var actual = read();
            return actual.Enabled == enabled ? actual : actual with { Message = $"设置登录启动失败：{actual.Message}" };
        }
        catch (Exception error) when (IsRegistrationError(error))
        {
            return read() with { Message = $"设置登录启动失败：{error.Message}" };
        }
    }

    private static bool IsRegistrationError(Exception error) => error is IOException or UnauthorizedAccessException or
        System.Security.SecurityException or ArgumentException or InvalidOperationException or NotSupportedException;

    public static void Enable()
    {
        if (!OperatingSystem.IsWindows()) return;
        var executable = Environment.ProcessPath ?? throw new IOException("无法确定当前程序路径");
        if (!Path.IsPathFullyQualified(executable) || !File.Exists(executable)) throw new IOException("当前程序路径不可用");
        var command = Command(executable);
        if (command.Length > 260) throw new IOException("程序路径太长，Windows Run 启动项最多支持 260 字符");
        using var key = Registry.CurrentUser.CreateSubKey(KeyPath);
        key.SetValue(ValueName, command, RegistryValueKind.String);
        // Only an explicit user enable changes this app's approval; ordinary settings saves never do.
        using var approval = Registry.CurrentUser.OpenSubKey(ApprovalPath, writable: true);
        approval?.DeleteValue(ValueName, throwOnMissingValue: false);
    }

    public static void Disable()
    {
        if (!OperatingSystem.IsWindows()) return;
        using var key = Registry.CurrentUser.OpenSubKey(KeyPath, writable: true);
        key?.DeleteValue(ValueName, throwOnMissingValue: false);
    }
}

public sealed class PairingSecretStore
{
    private readonly string _path = Path.Combine(AgentPagerPaths.DataRoot, "pairing-secret.bin");

    public byte[] LoadOrCreate()
    {
        Directory.CreateDirectory(AgentPagerPaths.DataRoot);
        if (File.Exists(_path))
            return Unprotect(File.ReadAllBytes(_path));
        var value = RandomNumberGenerator.GetBytes(32);
        File.WriteAllBytes(_path, Protect(value));
        return value;
    }

    private static byte[] Protect(byte[] value) => Crypt(value, protect: true);
    private static byte[] Unprotect(byte[] value) => Crypt(value, protect: false);

    internal static byte[] Crypt(byte[] value, bool protect)
    {
        if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException("DPAPI 仅支持 Windows。");
        var input = new DataBlob(value);
        var output = new DataBlob();
        try
        {
            var success = protect
                ? CryptProtectData(ref input, null, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, 1, out output)
                : CryptUnprotectData(ref input, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, 1, out output);
            if (!success) throw new CryptographicException(Marshal.GetLastWin32Error());
            var result = new byte[output.Length];
            Marshal.Copy(output.Data, result, 0, output.Length);
            return result;
        }
        finally
        {
            input.Dispose();
            output.DisposeLocal();
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct DataBlob
    {
        public int Length;
        public IntPtr Data;
        public DataBlob(byte[] value)
        {
            Length = value.Length;
            Data = Marshal.AllocHGlobal(value.Length);
            Marshal.Copy(value, 0, Data, value.Length);
        }
        public void Dispose()
        {
            if (Data != IntPtr.Zero)
            {
                for (var i = 0; i < Length; i++) Marshal.WriteByte(Data, i, 0);
                Marshal.FreeHGlobal(Data);
            }
            Data = IntPtr.Zero;
        }
        public void DisposeLocal()
        {
            if (Data != IntPtr.Zero)
            {
                for (var i = 0; i < Length; i++) Marshal.WriteByte(Data, i, 0);
                LocalFree(Data);
            }
            Data = IntPtr.Zero;
        }
    }

    [DllImport("crypt32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CryptProtectData(ref DataBlob dataIn, string? description, IntPtr optionalEntropy,
        IntPtr reserved, IntPtr promptStruct, int flags, out DataBlob dataOut);

    [DllImport("crypt32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CryptUnprotectData(ref DataBlob dataIn, IntPtr description, IntPtr optionalEntropy,
        IntPtr reserved, IntPtr promptStruct, int flags, out DataBlob dataOut);

    [DllImport("kernel32.dll")]
    private static extern IntPtr LocalFree(IntPtr memory);
}

/// <summary>Only DPAPI ciphertext is persisted; tokens are bound to the exact service URL.</summary>
public sealed class HermesAccessTokenStore
{
    private readonly string _path;
    private readonly Func<byte[], byte[]> _protect;
    private readonly Func<byte[], byte[]> _unprotect;
    public HermesAccessTokenStore() : this(Path.Combine(AgentPagerPaths.DataRoot, "hermes-access-token.bin"),
        value => PairingSecretStore.Crypt(value, true), value => PairingSecretStore.Crypt(value, false)) { }
    internal HermesAccessTokenStore(string path, Func<byte[], byte[]> protect, Func<byte[], byte[]> unprotect)
    { _path = path; _protect = protect; _unprotect = unprotect; }

    internal byte[]? ReadProtected()
    {
        if (!File.Exists(_path)) return null;
        if (new FileInfo(_path).Length > 65536) throw new CryptographicException("访问令牌文件无效。");
        return File.ReadAllBytes(_path);
    }
    internal void RestoreProtected(byte[]? data)
    {
        if (data is null) { File.Delete(_path); return; }
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(_path))!);
        var temporary = _path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try { File.WriteAllBytes(temporary, data); File.Move(temporary, _path, true); }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
    private const string AccountMarker = "account-session-v1\n";
    private sealed record StoredAccount(string Url, string? Profile, HermesAccountSession Session);
    private string? ReadValue()
    {
        var encrypted = ReadProtected();
        if (encrypted is null) return null;
        byte[] plain;
        try { plain = _unprotect(encrypted); }
        catch (Exception e) when (e is ArgumentException or CryptographicException)
        { throw new CryptographicException("无法解密 Hermes 凭据，请重新登录或录入令牌。"); }
        try { return new System.Text.UTF8Encoding(false, true).GetString(plain); }
        catch (System.Text.DecoderFallbackException) { throw new CryptographicException("Hermes 凭据文件无效。"); }
        finally { CryptographicOperations.ZeroMemory(plain); }
    }
    private static HermesAccountSession? ReadSession(string value, string url, string? profile)
    {
        try
        {
            var stored = JsonSerializer.Deserialize<StoredAccount>(value[AccountMarker.Length..], new JsonSerializerOptions { MaxDepth = 8 })
                ?? throw new CryptographicException("Hermes 会话文件无效。");
            if (stored.Url != url || stored.Profile != profile) return null;
            NativeHermesAuthClient.ValidateSession(stored.Session);
            return stored.Session;
        }
        catch (Exception e) when (e is JsonException or ArgumentException or IOException or NullReferenceException)
        { throw new CryptographicException("Hermes 会话文件无效，请重新登录。"); }
    }
    public HermesAccountSession? LoadSession(string url, string? profile = null)
    {
        var value = ReadValue();
        return value is not null && value.StartsWith(AccountMarker, StringComparison.Ordinal) ? ReadSession(value, url, profile) : null;
    }
    public string? Load(string url, string? profile = null)
    {
        var value = ReadValue();
        if (value is null) return null;
        if (value.StartsWith(AccountMarker, StringComparison.Ordinal)) return ReadSession(value, url, profile)?.AccessToken;
        var split = value.IndexOf('\n');
        if (split < 1) throw new CryptographicException("访问令牌文件无效。");
        if (!string.Equals(value[..split], url, StringComparison.Ordinal)) return null;
        var rest = value[(split + 1)..];
        var separator = rest.IndexOf('\n');
        if (separator < 0) throw new CryptographicException("访问令牌文件无效。");
        if (!string.Equals(rest[..separator], profile ?? "", StringComparison.Ordinal)) return null;
        var token = rest[(separator + 1)..];
        NativeHermesUsageClient.ValidateToken(token);
        return token;
    }
    public void SaveSession(string url, string? profile, HermesAccountSession session)
    {
        url = NativeHermesUsageClient.ValidateBaseUrl(url).AbsoluteUri;
        profile = NativeHermesUsageClient.ValidateProfile(profile);
        NativeHermesAuthClient.ValidateSession(session);
        var plain = System.Text.Encoding.UTF8.GetBytes(AccountMarker + JsonSerializer.Serialize(new StoredAccount(url, profile, session)));
        var previous = ReadProtected();
        try
        {
            RestoreProtected(_protect(plain));
            if (LoadSession(url, profile) != session) throw new CryptographicException("Hermes 会话保存后校验失败。");
        }
        catch
        {
            RestoreProtected(previous);
            throw;
        }
        finally { CryptographicOperations.ZeroMemory(plain); }
    }
    public void Save(string url, string token, string? profile = null)
    {
        NativeHermesUsageClient.ValidateToken(token);
        if (token.Length == 0) { RestoreProtected(null); return; }
        url = NativeHermesUsageClient.ValidateBaseUrl(url).AbsoluteUri;
        profile = NativeHermesUsageClient.ValidateProfile(profile);
        var plain = System.Text.Encoding.UTF8.GetBytes(url + "\n" + profile + "\n" + token);
        try { RestoreProtected(_protect(plain)); }
        finally { CryptographicOperations.ZeroMemory(plain); }
        if (Load(url, profile) != token) throw new CryptographicException("访问令牌保存后校验失败。");
    }
}

public sealed class DailyFileLog
{
    private readonly object _lock = new();
    private readonly string _defaultDirectory;
    private string _activeDirectory;
    private string _preferredDirectory;
    private string? _lastError;

    public DailyFileLog(string? configuredDirectory = null, string? defaultDirectory = null)
    {
        _defaultDirectory = NormalizeDirectory(defaultDirectory ?? AgentPagerPaths.LogsDirectory);
        _preferredDirectory = configuredDirectory ?? _defaultDirectory;
        _activeDirectory = _defaultDirectory;
        lock (_lock) PrepareDestination();
    }

    // UI status reads must remain nonblocking while a disconnected drive or a settings save is slow.
    public string ActiveDirectory => Volatile.Read(ref _activeDirectory);
    public string? LastError => Volatile.Read(ref _lastError);

    public bool TrySetDirectory(string? directory, Action<string?> persist, out string? error)
    {
        lock (_lock)
        {
            try
            {
                var path = NormalizeDirectory(directory ?? _defaultDirectory);
                ProbeDirectory(path);
                persist(SamePath(path, _defaultDirectory) ? null : path);
                _activeDirectory = _preferredDirectory = path;
                _lastError = null;
                error = null;
                return true;
            }
            catch (Exception failure) when (IsFileError(failure))
            {
                error = failure.Message;
                return false;
            }
        }
    }

    private static bool SamePath(string left, string right) => string.Equals(left, right,
        OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal);

    private static string NormalizeDirectory(string value)
    {
        value = Environment.ExpandEnvironmentVariables(value.Trim());
        if (!Path.IsPathFullyQualified(value)) throw new ArgumentException("请输入完整的绝对目录路径。");
        var path = Path.TrimEndingDirectorySeparator(Path.GetFullPath(value));
        if (OperatingSystem.IsWindows())
        {
            if (path.StartsWith(@"\\?\", StringComparison.Ordinal) || path.StartsWith(@"\\.\", StringComparison.Ordinal))
                throw new ArgumentException("不支持设备目录路径。");
            var relative = path[Path.GetPathRoot(path)!.Length..];
            foreach (var segment in relative.Split(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar))
            {
                if (segment.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0 || segment.EndsWith('.') || segment.EndsWith(' '))
                    throw new ArgumentException("目录名称包含无效字符。");
            }
        }
        return path;
    }

    private static void ProbeDirectory(string path)
    {
        if (OperatingSystem.IsWindows() && Path.GetPathRoot(path) is { Length: 3 } root && !new DriveInfo(root).IsReady)
            throw new IOException("日志驱动器未连接或未就绪。");
        Directory.CreateDirectory(path);
        var probe = Path.Combine(path, ".agentpager-write-test-" + Guid.NewGuid().ToString("N"));
        using (var stream = new FileStream(probe, FileMode.CreateNew, FileAccess.Write, FileShare.None,
                   1, FileOptions.DeleteOnClose))
        {
            stream.WriteByte(0);
            stream.Flush(flushToDisk: true);
        }
        var daily = Path.Combine(path, $"agentpager-{DateTime.Now:yyyy-MM-dd}.log");
        if (File.Exists(daily))
            using (File.Open(daily, FileMode.Open, FileAccess.Write, FileShare.ReadWrite)) { }
    }

    private static bool IsFileError(Exception error) => error is IOException or UnauthorizedAccessException or
        ArgumentException or NotSupportedException or System.Security.SecurityException;

    private void PrepareDestination() => WithDestination(ProbeDirectory);

    // Never let an unavailable removable/network drive take down the bridge or its error handler.
    // Only new writes switch destination: existing logs are never moved, deleted, or pruned.
    private void WithDestination(Action<string> operation)
    {
        try
        {
            var path = NormalizeDirectory(_preferredDirectory);
            operation(path);
            _activeDirectory = path;
            _lastError = null;
            return;
        }
        catch (Exception failure) when (IsFileError(failure))
        {
            _lastError = $"日志目录不可用（{_preferredDirectory}）：{failure.Message}";
        }
        _activeDirectory = _defaultDirectory;
        try
        {
            operation(_defaultDirectory);
            _lastError += $"；暂写默认目录：{_defaultDirectory}。原设置已保留，目录恢复后自动重试。";
        }
        catch (Exception failure) when (IsFileError(failure))
        {
            _lastError += $"；默认目录也不可写，日志暂停：{failure.Message}";
        }
    }

    public void Write(string level, string message)
    {
        var line = $"{DateTimeOffset.Now:O} [{level}] {message}{Environment.NewLine}";
        lock (_lock) WithDestination(directory =>
        {
            Directory.CreateDirectory(directory);
            var path = Path.Combine(directory, $"agentpager-{DateTime.Now:yyyy-MM-dd}.log");
            File.AppendAllText(path, line);
        });
    }
}
