using System.Security.Cryptography;
using System.Text;

namespace AgentPager.Bridge;

internal sealed class HermesPluginSetup(byte[] bridgeSecret)
{
    private const string ResourceName = "AgentPager.Bridge.HermesPlugin.js";
    private const string TokenMarker = "AGENTPAGER_LOCAL_STATUS_TOKEN";
    public string Token { get; } = Convert.ToHexString(HMACSHA256.HashData(bridgeSecret, "AgentPager Hermes status only v1"u8));
    public string PluginPath { get; } = Path.Combine(ResolveHome(), "desktop-plugins", "agentpager-status", "plugin.js");
    public bool IsInstalled => File.Exists(PluginPath);

    public string UpdateStatus { get; private set; } = "Desktop 状态脚本尚未检查";

    // Exact SHA256 of shipped UTF-8 templates, with only the local token normalized.
    // Never recognize scripts by id, name, version comments or loose code fragments.
    private static readonly HashSet<string> ShippedTemplates = new(StringComparer.OrdinalIgnoreCase)
    {
        "1d0d352a4bcd367dc8518f94fbc0248b7022a4ec25ef2a40e74a1073560fe232", // r2 / r3
        "6c7d64ab8382638e6ffc1d056174d0f2279e111670c86ca1f48b9de255c6bfa4", // r4 / r4.1
    };

    public void UpgradeInstalled()
    {
        if (!IsInstalled) { UpdateStatus = "未安装 Desktop 状态脚本；未自动安装"; return; }
        try
        {
            if ((File.GetAttributes(PluginPath) & FileAttributes.ReparsePoint) != 0)
            { UpdateStatus = "Desktop 状态脚本为链接，已保留；请手动检查"; return; }
            var template = ReadTemplate();
            var source = template.Replace(TokenMarker, Token, StringComparison.Ordinal);
            var existing = File.ReadAllText(PluginPath);
            if (existing == source) { UpdateStatus = "Desktop 状态脚本已是内置最新版本"; return; }
            var normalized = NormalizeToken(existing);
            if (normalized is null || normalized != template &&
                !ShippedTemplates.Contains(Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(normalized)))))
            { UpdateStatus = "Desktop 状态脚本有自定义或来源未知，未覆盖；请备份后手动安装 / 更新"; return; }
            var backup = PluginPath + $".bak-{DateTime.UtcNow:yyyyMMddHHmmss}-{Guid.NewGuid():N}";
            Replace(source, existing, backup);
            UpdateStatus = "已安全更新已安装的 Desktop 状态脚本（已备份）；保留原启用/禁用状态。若未热重载，请在 Hermes 执行 Reload desktop plugins";
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or InvalidOperationException)
        { UpdateStatus = "Desktop 状态脚本更新失败，保留原状态；请检查文件权限后重试"; }
    }

    private static string? NormalizeToken(string source)
    {
        var expression = new System.Text.RegularExpressions.Regex(@"(?m)^const bridgeToken = '(?:[0-9a-fA-F]{64}|AGENTPAGER_LOCAL_STATUS_TOKEN)';\r?$");
        if (expression.Matches(source).Count != 1) return null;
        return expression.Replace(source, match => "const bridgeToken = '" + TokenMarker + "';" + (match.Value.EndsWith('\r') ? "\r" : ""));
    }

    private static string ReadTemplate()
    {
        using var resource = typeof(HermesPluginSetup).Assembly.GetManifestResourceStream(ResourceName)
            ?? throw new InvalidOperationException("Bridge 缺少内置的 Hermes 插件资源。");
        using var reader = new StreamReader(resource, Encoding.UTF8);
        var template = reader.ReadToEnd();
        if (!template.Contains(TokenMarker, StringComparison.Ordinal))
            throw new InvalidOperationException("内置 Hermes 插件资源无令牌占位符。");
        return template;
    }

    // Explicit user action may repair an unknown/customized script, but still takes a backup.
    public void Install()
    {
        var source = ReadTemplate().Replace(TokenMarker, Token, StringComparison.Ordinal);
        var existing = IsInstalled ? File.ReadAllText(PluginPath) : null;
        var backup = File.Exists(PluginPath + ".bak") ? PluginPath + $".bak-{Guid.NewGuid():N}" : PluginPath + ".bak";
        if (existing != source) Replace(source, existing, backup);
        UpdateStatus = "Desktop 状态脚本已安装 / 更新；请在 Hermes 检查插件开关（未自动启用）";
    }

    private void Replace(string source, string? existing, string backup)
    {
        var folder = Path.GetDirectoryName(PluginPath)!;
        Directory.CreateDirectory(folder);
        var temporary = Path.Combine(folder, $"agentpager-{Guid.NewGuid():N}.tmp");
        try
        {
            File.WriteAllText(temporary, source, new UTF8Encoding(false));
            // Refuse a concurrently edited script rather than overwriting a newer user save.
            if ((File.Exists(PluginPath) ? File.ReadAllText(PluginPath) : null) != existing)
                throw new IOException("Desktop 状态脚本检查后已变化。");
            if (existing is not null) File.Copy(PluginPath, backup, overwrite: false);
            File.Move(temporary, PluginPath, overwrite: true);
            if (File.ReadAllText(PluginPath) != source) throw new IOException("Desktop 状态脚本写入后校验失败。");
        }
        finally { File.Delete(temporary); }
    }

    private static string? Setting(string name) => Environment.GetEnvironmentVariable(name)
        ?? Environment.GetEnvironmentVariable(name, EnvironmentVariableTarget.User);

    private static string ResolveHome()
    {
        if (Setting("HERMES_HOME") is { Length: > 0 } configured)
        {
            var full = Path.TrimEndingDirectorySeparator(Path.GetFullPath(configured));
            var parent = Directory.GetParent(full);
            return parent?.Name.Equals("profiles", StringComparison.OrdinalIgnoreCase) == true
                ? parent.Parent!.FullName : full;
        }
        if (Setting("HERMES_DESKTOP_USER_DATA_DIR") is { Length: > 0 } data)
            return Path.Combine(data, "hermes-home");
        var suffix = Setting("HERMES_DATA_DIR_SUFFIX") ?? "";
        var current = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "hermes" + suffix);
        var legacy = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".hermes");
        return suffix.Length == 0 && !Directory.Exists(current) && Directory.Exists(legacy) ? legacy : current;
    }
}
