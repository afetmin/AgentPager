using System.Reflection;
using AgentPager.Bridge;

internal static class HermesPluginUpgradeTests
{
    public static void Run()
    {
        var home = Path.Combine(Path.GetTempPath(), "agentpager-upgrade-" + Guid.NewGuid().ToString("N"));
        var previous = Environment.GetEnvironmentVariable("HERMES_HOME");
        Environment.SetEnvironmentVariable("HERMES_HOME", home);
        try
        {
            var setup = new HermesPluginSetup(new byte[32]);
            var method = typeof(HermesPluginSetup).GetMethod("UpgradeInstalled", BindingFlags.Public | BindingFlags.Instance);
            Check(method is not null, "Installed Desktop status scripts need an explicit safe startup upgrade path");
            void Upgrade() => method!.Invoke(setup, null);
            Upgrade();
            Check(!Directory.Exists(home), "Startup must not install for a user who never installed the integration");
            setup.Install();
            var current = File.ReadAllText(setup.PluginPath);
            var oldTime = DateTime.UtcNow.AddDays(-2); File.SetLastWriteTimeUtc(setup.PluginPath, oldTime);
            Upgrade();
            Check(File.GetLastWriteTimeUtc(setup.PluginPath) == oldTime, "Identical embedded script must not be rewritten");
            var folder = Path.GetDirectoryName(setup.PluginPath)!;
            var disabled = Path.Combine(home, "disabled-plugins.json"); File.WriteAllText(disabled, "[\"agentpager-status\"]");
            using var fixture = typeof(HermesPluginUpgradeTests).Assembly.GetManifestResourceStream("AgentPager.Tests.LegacyPlugin.js")!;
            using var reader = new StreamReader(fixture); var legacy = reader.ReadToEnd().Replace("AGENTPAGER_LOCAL_STATUS_TOKEN", new string('a', 64));
            File.WriteAllText(setup.PluginPath, legacy);
            Upgrade();
            Check(File.ReadAllText(setup.PluginPath) == current, "Known shipped r2/r3 script must automatically upgrade to the embedded script");
            Check(Directory.GetFiles(folder, "plugin.js.bak*").Any(path => File.ReadAllText(path) == legacy), "Automatic replacement must preserve exact previous script in a backup");
            Check(File.ReadAllText(disabled) == "[\"agentpager-status\"]", "Upgrading must never write enable/disable state");
            var custom = legacy + "\n// user customization\n"; File.WriteAllText(setup.PluginPath, custom);
            var count = Directory.GetFiles(folder).Length;
            Upgrade();
            Check(File.ReadAllText(setup.PluginPath) == custom && Directory.GetFiles(folder).Length == count, "Matching plugin id or old version must not authorize overwriting customized code");
            Check((string?)typeof(HermesPluginSetup).GetProperty("UpdateStatus")?.GetValue(setup) is { Length: > 0 }, "Skipped custom updates need a visible explanation");
            setup.Install();
            File.WriteAllText(setup.PluginPath, "second explicit repair"); setup.Install();
            Check(File.ReadAllText(setup.PluginPath) == current && Directory.GetFiles(folder, "plugin.js.bak*").Any(path => File.ReadAllText(path) == "second explicit repair"),
                "Repeated explicit repairs must preserve old backups without blocking the requested install");
            Console.WriteLine("PASS safe installed-only Desktop status upgrade: shipped legacy hash, backup, atomic replacement, no-op, custom code and disabled-state preservation");
        }
        finally { Environment.SetEnvironmentVariable("HERMES_HOME", previous); if (Directory.Exists(home)) Directory.Delete(home, true); }
    }
    private static void Check(bool condition, string message) { if (!condition) throw new Exception(message); }
}
