using AgentPager.Bridge;
using AgentPager.Core;
using Microsoft.Win32;

internal static class NativeWindowsProbe
{
    public static int Run()
    {
        if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException();
        Exception? error = null;
        var thread = new Thread(() => { try { Verify(); } catch (Exception e) { error = e; } });
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start(); thread.Join();
        if (error is not null) { Console.WriteLine("FAIL native Windows probe: " + error.GetType().Name); return 1; }
        return 0;
    }

    private static void Verify()
    {
        // Fixture-only HERMES_HOME; never edits the user's installed integration or enable toggle.
        HermesPluginUpgradeTests.Run();
        var folder = Path.Combine(Path.GetTempPath(), "AgentPager-verification-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(folder);
        try
        {
            var path = Path.Combine(folder, "fixture-session.bin");
            var store = new HermesAccessTokenStore(path, b => PairingSecretStore.Crypt(b, true), b => PairingSecretStore.Crypt(b, false));
            var session = new HermesAccountSession("fixture-" + Guid.NewGuid().ToString("N"), "fixture-" + Guid.NewGuid().ToString("N"), "basic", "fixture-user", DateTimeOffset.UtcNow.AddMinutes(10));
            store.SaveSession("https://fixture.invalid/", "fixture", session);
            if (new HermesAccessTokenStore(path, b => PairingSecretStore.Crypt(b, true), b => PairingSecretStore.Crypt(b, false)).LoadSession("https://fixture.invalid/", "fixture") != session)
                throw new Exception("DPAPI readback mismatch");
            var bytes = File.ReadAllBytes(path);
            if (System.Text.Encoding.UTF8.GetString(bytes).Contains(session.AccessToken) || store.LoadSession("https://other.invalid/", "fixture") is not null)
                throw new Exception("Source binding or ciphertext failure");
            store.RestoreProtected(null);
            if (File.Exists(path)) throw new Exception("Fixture credential deletion failed");
            Console.WriteLine("PASS native Windows current-user DPAPI: production encryption, file save/readback, source binding, deletion");
            const string run = @"Software\Microsoft\Windows\CurrentVersion\Run";
            using var key = Registry.CurrentUser.OpenSubKey(run);
            var before = key?.GetValue("AgentPager") as string;
            var legacy = StartupRegistration.LegacyWebStartupEntries();
            if ((key?.GetValue("AgentPager") as string) != before) throw new Exception("Read-only inspection changed Run key");
            Console.WriteLine("READONLY startup: existing AgentPager Run item=" + (before is not null) + "; known legacy web shortcuts=" + legacy.Count);
            Console.WriteLine("PASS no real startup item, account, source setting or running application was changed");
        }
        finally { Directory.Delete(folder, true); }
    }
}
