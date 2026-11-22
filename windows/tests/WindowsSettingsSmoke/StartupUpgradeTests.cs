using AgentPager.Bridge;

internal static class StartupUpgradeTests
{
    public static void Run()
    {
        const string oldExe = @"E:\old\AgentPagerBridge.exe";
        const string newExe = @"E:\new\AgentPagerBridge.exe";
        var old = StartupRegistration.Command(oldExe);
        var disabled = new byte[] { 3,0,0,0 };
        if (StartupRegistration.Evaluate(old, null, newExe).Enabled != false ||
            StartupRegistration.Evaluate(old, disabled, newExe).Enabled != false ||
            StartupRegistration.Evaluate(StartupRegistration.Command(newExe), disabled, newExe).Enabled != false)
            throw new Exception("Settings must not treat stale paths or a Windows-disabled entry as active");
        if(!StartupRegistration.IsKnownLegacyWebTarget(@"F:\tools\AgentPagerChatGPTWebBridge.exe") ||
            !StartupRegistration.IsKnownLegacyWebTarget(@"F:\tools\AgentPagerChatGPTMonitor.exe") ||
            StartupRegistration.IsKnownLegacyWebTarget(@"F:\tools\unrelated.exe"))throw new Exception("Legacy cleanup allowlist invalid");
        var root=Path.Combine(Path.GetTempPath(),"startup-upgrade-"+Guid.NewGuid().ToString("N"));Directory.CreateDirectory(root);
        try
        {
            var startup=Path.Combine(root,"Startup");Directory.CreateDirectory(startup);
            var oldLink=Path.Combine(startup,"Legacy.lnk");File.WriteAllText(oldLink,"synthetic shortcut bytes");
            var other=Path.Combine(startup,"unrelated.lnk");File.WriteAllText(other,"leave alone");
            var result=StartupRegistration.BackupLegacyEntries([new("Legacy",oldLink)],Path.Combine(root,"backup"));
            if(!result.Success||result.DisabledCount!=1||File.Exists(oldLink)||!File.Exists(other)||
                File.ReadAllText(Directory.GetFiles(Path.Combine(root,"backup"),"*.lnk",SearchOption.AllDirectories).Single())!="synthetic shortcut bytes")
                throw new Exception("Explicit cleanup must preserve original shortcut bytes in backup and unrelated entries untouched");
        }
        finally{Directory.Delete(root,true);}
        Console.WriteLine("PASS startup upgrade: stale/disabled status and explicit legacy backup cleanup");
    }
}
