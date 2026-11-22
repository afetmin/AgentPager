using AgentPager.Bridge;
using System.Diagnostics;

if (args.Contains("--native-windows-probe", StringComparer.Ordinal)) return NativeWindowsProbe.Run();
if (args.Contains("--codex-status-probe", StringComparer.Ordinal)) { CodexRolloutStatusTests.Run(); return 0; }
if (args.Contains("--hermes-transport-probe", StringComparer.Ordinal)) { await NativeHermesSafetyTests.Run(); return 0; }
var root = Environment.GetEnvironmentVariable("AGENTPAGER_SETTINGS_TEST_ROOT") ??
    Path.Combine(Path.GetTempPath(), "agentpager-settings-" + Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(root);
// Set profile variables before CLR startup: Environment may cache special-folder paths.
if (!OperatingSystem.IsWindows() && Environment.GetEnvironmentVariable("AGENTPAGER_SETTINGS_TEST_ROOT") is null)
{
    var start = new ProcessStartInfo(Environment.ProcessPath!) { UseShellExecute = false };
    if (Path.GetFileNameWithoutExtension(Environment.ProcessPath) == "dotnet")
        start.ArgumentList.Add(Path.Combine(AppContext.BaseDirectory, typeof(BridgeSettings).Assembly.GetName().Name + ".dll"));
    start.Environment["AGENTPAGER_SETTINGS_TEST_ROOT"] = root;
    start.Environment["XDG_DATA_HOME"] = Path.Combine(root, "profile");
    start.Environment["HOME"] = Path.Combine(root, "home");
    Directory.CreateDirectory(start.Environment["XDG_DATA_HOME"]!);
    Directory.CreateDirectory(start.Environment["HOME"]!);
    try
    {
        using var child = Process.Start(start)!;
        await child.WaitForExitAsync();
        return child.ExitCode;
    }
    finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
}
try
{
    CodexRolloutStatusTests.Run();
    await WebSocketShutdownTests.Run();
    PhoneSecurityTests.IdentitySurvivesRestart(root);
    if (!OperatingSystem.IsWindows()) { await EnabledSourcesTests.Run(); await HermesProducerInteropTests.Run(); }
    StartupUpgradeTests.Run();
    var original = Path.Combine(root, "default");
    var chosen = Path.Combine(root, "custom logs 中文");
    var log = new DailyFileLog(null, original);
    log.Write("INFO", "before switch");
    string? persisted = null;
    if (!log.TrySetDirectory(chosen, value => persisted = value, out var error))
        throw new Exception("Custom directory rejected: " + error);
    log.Write("INFO", "after switch");
    if (persisted != chosen || log.ActiveDirectory != chosen)
        throw new Exception("Selection not persisted or activated");
    if (!File.ReadAllText(Directory.GetFiles(original, "*.log").Single()).Contains("before switch") ||
        !File.ReadAllText(Directory.GetFiles(chosen, "*.log").Single()).Contains("after switch"))
        throw new Exception("Switch must leave original logs and write new events to chosen directory");
    Console.WriteLine("PASS log selection, live switch, and old logs preserved");

    foreach (var invalid in new[] { "relative/logs", "bad\0path", Path.Combine(root, "blocked", "logs") })
    {
        File.WriteAllText(Path.Combine(root, "blocked"), "not a directory");
        if (log.TrySetDirectory(invalid, _ => throw new Exception("Must not persist an invalid selection"), out error))
            throw new Exception("Invalid path accepted: " + invalid);
        if (log.ActiveDirectory != chosen || string.IsNullOrEmpty(error))
            throw new Exception("Failed selection must leave active directory and report error");
    }
    if (OperatingSystem.IsLinux() && log.TrySetDirectory("/proc/self/agentpager-unwritable", _ =>
            throw new Exception("Must not persist an OS-denied directory"), out error))
        throw new Exception("OS-denied directory was accepted");
    if (log.TrySetDirectory(Path.Combine(root, "save-failure"), _ => throw new IOException("settings disk full"), out error) ||
        log.ActiveDirectory != chosen || string.IsNullOrEmpty(error))
        throw new Exception("Persistence failure must leave current log selection unchanged");
    Console.WriteLine("PASS invalid/unwritable selection and persistence failure are transactional");

    Directory.Move(chosen, chosen + "-offline");
    File.WriteAllText(chosen, "drive no longer available");
    log.Write("WARN", "survive disconnect");
    if (log.ActiveDirectory != original || string.IsNullOrEmpty(log.LastError) ||
        !File.ReadAllText(Directory.GetFiles(original, "*.log").Single()).Contains("survive disconnect"))
        throw new Exception("Disconnected destination must fall back and report the actual directory");
    var restart = new DailyFileLog(chosen, original);
    restart.Write("INFO", "restart fallback");
    if (restart.ActiveDirectory != original || string.IsNullOrEmpty(restart.LastError))
        throw new Exception("Unavailable saved destination must not prevent application startup");
    var noDestination = new DailyFileLog(chosen, Path.Combine(root, "blocked", "fallback"));
    noDestination.Write("ERROR", "neither destination writable");
    if (string.IsNullOrEmpty(noDestination.LastError)) throw new Exception("Logging loss must be visible");
    File.Delete(chosen);
    Directory.Move(chosen + "-offline", chosen);
    log.Write("INFO", "recovered destination");
    if (log.ActiveDirectory != chosen || log.LastError is not null)
        throw new Exception("Restored configured destination must recover on next write");
    if (!log.TrySetDirectory(null, value => persisted = value, out error) || persisted is not null || log.ActiveDirectory != original)
        throw new Exception("Reset must clear override and activate default directory");
    Console.WriteLine("PASS disconnected destination, restart fallback, complete write failure, recovery, reset");

    using (var saving = new ManualResetEventSlim())
    using (var release = new ManualResetEventSlim())
    {
        var pending = Task.Run(() => log.TrySetDirectory(Path.Combine(root, "slow-switch"), _ =>
        {
            saving.Set();
            release.Wait();
        }, out _));
        try
        {
            if (!saving.Wait(TimeSpan.FromSeconds(5))) throw new Exception("Selection did not reach persistence");
            var read = Task.Run(() => (log.ActiveDirectory, log.LastError));
            if (await Task.WhenAny(read, Task.Delay(500)) != read)
                throw new Exception("UI status reads must not wait on slow/disconnected filesystem operations");
        }
        finally { release.Set(); await pending; }
    }
    Console.WriteLine("PASS status reads do not block behind slow settings I/O");

    var settingsFile = Path.Combine(root, "preferences", "settings.json");
    var settings = new BridgeSettings { LogDirectory = chosen, LaunchAtLogin = false };
    settings.Save(settingsFile);
    var reloaded = BridgeSettings.Load(settingsFile);
    if (reloaded.LogDirectory != chosen || reloaded.LaunchAtLogin)
        throw new Exception("Nondefault logging and startup preference must survive restart");
    var old = Path.Combine(chosen, "agentpager-2001-01-01.log");
    File.WriteAllText(old, "keep me");
    File.SetLastWriteTimeUtc(old, DateTime.UtcNow.AddYears(-2));
    new DailyFileLog(reloaded.LogDirectory, original).Write("INFO", "reloaded setting");
    if (!File.Exists(old)) throw new Exception("Old logs must not be pruned at startup");
    settings.LogDirectory = null;
    settings.Save(settingsFile);
    if (BridgeSettings.Load(settingsFile).LogDirectory is not null || File.ReadAllText(settingsFile).Contains("LogDirectory"))
        throw new Exception("Default must persist without a hardcoded user-specific log override");
    File.WriteAllText(settingsFile, "{ broken json");
    if (BridgeSettings.Load(settingsFile).LogDirectory is not null)
        throw new Exception("Corrupt settings must safely use default logs");
    Console.WriteLine("PASS nondefault persistence, default omission, corrupt settings, and no log pruning");

    var executable = @"C:\Program Files\AgentPager 中文\AgentPagerBridge.exe";
    var command = StartupRegistration.Command(executable);
    if (command != "\"" + executable + "\" --background") throw new Exception("Startup executable must be quoted");
    if (StartupRegistration.Evaluate(null, null, executable).Enabled != false ||
        StartupRegistration.Evaluate(command, null, executable).Enabled != true ||
        StartupRegistration.Evaluate(command, new byte[] { 0, 0, 0, 0 }, executable).Enabled != true ||
        StartupRegistration.Evaluate(command, new byte[] { 2, 0, 0, 0 }, executable).Enabled != true ||
        StartupRegistration.Evaluate(command, new byte[] { 3, 0, 0, 0 }, executable).Enabled != false ||
        StartupRegistration.Evaluate(command, new byte[] { 255 }, executable).Enabled is not null ||
        StartupRegistration.Evaluate("\"C:\\old\\AgentPager.exe\" --background", null, executable).Enabled != false)
        throw new Exception("Startup state must reflect actual executable and Windows startup approval");
    var actual = new StartupStatus(false, "disabled");
    var result = StartupRegistration.Change(true, _ => { }, () => actual);
    if (result.Enabled != false || !result.Message.Contains("失败"))
        throw new Exception("Successful registry write alone must not report startup enabled");
    result = StartupRegistration.Change(true, _ => throw new UnauthorizedAccessException("denied"), () => actual);
    if (result.Enabled != false || !result.Message.Contains("denied"))
        throw new Exception("Registry access denial must retain truthful status and show failure");
    result = StartupRegistration.Change(true, enabled => actual = new(enabled, "enabled"), () => actual);
    if (result.Enabled != true) throw new Exception("Verified startup enable rejected");
    result = StartupRegistration.Change(false, enabled => actual = new(enabled, "disabled"), () => actual);
    if (result.Enabled != false) throw new Exception("Verified startup disable rejected");
    Console.WriteLine("PASS startup command quoting, actual/disabled/stale/unknown state, read-back, and failures");

    if (!OperatingSystem.IsWindows())
    {
        if (!AgentPager.Core.AgentPagerPaths.DataRoot.StartsWith(root, StringComparison.Ordinal))
            throw new Exception("Runtime test profile is not isolated");
        var runtimeSettings = new BridgeSettings { LogDirectory = chosen };
        await using var runtime = new BridgeRuntime(runtimeSettings, new byte[32], loopbackOnly: true);
        if (runtime.ActiveLogDirectory != chosen) throw new Exception("Runtime ignored saved custom log path");
        if (!runtime.TrySetLogDirectory(original, out error) || runtime.ActiveLogDirectory != original ||
            BridgeSettings.Load().LogDirectory != original)
            throw new Exception("Runtime must persist custom selection before activating it: " + error);
        if (runtime.TrySetLogDirectory("relative", out error) || runtime.Settings.LogDirectory != original)
            throw new Exception("Runtime must preserve preference after invalid edit");
        var savedPath = AgentPager.Core.AgentPagerPaths.SettingsFile;
        File.Move(savedPath, savedPath + ".backup");
        Directory.CreateDirectory(savedPath);
        if (runtime.TrySetLogDirectory(chosen, out error) || runtime.Settings.LogDirectory != original || runtime.ActiveLogDirectory != original)
            throw new Exception("Actual settings write failure must roll back runtime preference and writer");
        Directory.Delete(savedPath);
        File.Move(savedPath + ".backup", savedPath);
        if (BridgeSettings.Load().LogDirectory != original)
            throw new Exception("Failed save corrupted persisted preference");
        if (!runtime.TrySetLogDirectory(null, out error) || BridgeSettings.Load().LogDirectory is not null ||
            runtime.ActiveLogDirectory != AgentPager.Core.AgentPagerPaths.LogsDirectory)
            throw new Exception("Runtime reset must clear saved override and activate default");
        Console.WriteLine("PASS production BridgeRuntime saved-path initialization, switch, invalid edit, and reset");
    }
    if (!OperatingSystem.IsWindows()) { await NativeHermesTests.Run(); await HermesAuthTests.Run(); }
}
finally { Directory.Delete(root, true); }
return 0;
