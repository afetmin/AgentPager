using System.Runtime.InteropServices;
using System.Text.Json;
using AgentPager.Core;

namespace AgentPager.Bridge;

public sealed record LegacyStartupEntry(string Name, string Path);
public sealed record StartupCleanupResult(bool Success, int DisabledCount, string Message);

public static partial class StartupRegistration
{
    public static string? OtherRunningExecutable()
    {
        if(!OperatingSystem.IsWindows())return null;
        using var current=System.Diagnostics.Process.GetCurrentProcess();
        foreach(var candidate in System.Diagnostics.Process.GetProcessesByName("AgentPagerBridge"))
        {
            using(candidate)
            {
                try
                {
                    if(candidate.Id==current.Id || candidate.SessionId!=current.SessionId)continue;
                    var path=candidate.MainModule?.FileName;
                    if(path is not null && !string.Equals(path,Environment.ProcessPath,StringComparison.OrdinalIgnoreCase))return path;
                }
                catch(Exception e) when(e is System.ComponentModel.Win32Exception or InvalidOperationException or NotSupportedException) { }
            }
        }
        return null;
    }

    private static string FileName(string path)=>path.Replace('\\','/').Split('/').LastOrDefault() ?? "";
    internal static bool IsKnownLegacyWebTarget(string path)=>FileName(path).Equals("AgentPagerChatGPTMonitor.exe",StringComparison.OrdinalIgnoreCase) ||
        FileName(path).Equals("AgentPagerChatGPTWebBridge.exe",StringComparison.OrdinalIgnoreCase);

    public static IReadOnlyList<LegacyStartupEntry> LegacyWebStartupEntries()
    {
        if(!OperatingSystem.IsWindows())return [];
        var result=new List<LegacyStartupEntry>();
        object? shell=null;
        try
        {
            var type=Type.GetTypeFromProgID("WScript.Shell");
            if(type is null)return result;
            shell=Activator.CreateInstance(type);
            if(shell is null)return result;
            var folders=new[]{Environment.GetFolderPath(Environment.SpecialFolder.Startup),Environment.GetFolderPath(Environment.SpecialFolder.CommonStartup)};
            foreach(var folder in folders.Where(Directory.Exists).Distinct(StringComparer.OrdinalIgnoreCase))
                foreach(var path in Directory.EnumerateFiles(folder,"*.lnk"))
                {
                    object? link=null;
                    try
                    {
                        link=((dynamic)shell).CreateShortcut(path);
                        var target=(string)((dynamic)link).TargetPath;
                        if(IsKnownLegacyWebTarget(target))result.Add(new(Path.GetFileName(path),path));
                    }
                    catch(Exception e) when(e is COMException or IOException or UnauthorizedAccessException or System.Security.SecurityException) { }
                    finally {if(link is not null && Marshal.IsComObject(link))Marshal.ReleaseComObject(link);}
                }
        }
        catch(Exception e) when(e is COMException or IOException or UnauthorizedAccessException or System.Security.SecurityException or NotSupportedException) { }
        finally {if(shell is not null && Marshal.IsComObject(shell))Marshal.ReleaseComObject(shell);}
        return result;
    }

    public static StartupCleanupResult DisableLegacyWebStartup()=>BackupLegacyEntries(LegacyWebStartupEntries(),Path.Combine(AgentPagerPaths.DataRoot,"disabled-startup"));

    internal static StartupCleanupResult BackupLegacyEntries(IReadOnlyList<LegacyStartupEntry> entries,string backupRoot)
    {
        if(entries.Count==0)return new(true,0,"没有检测到旧网页监控启动项");
        var moved=new List<object>();var failed=0;
        var folder=Path.Combine(backupRoot,Guid.NewGuid().ToString("N"));
        try {Directory.CreateDirectory(folder);}
        catch(Exception e) when(IsRegistrationError(e)){return new(false,0,"无法创建启动项备份目录，未停用任何项目");}
        foreach(var entry in entries)
        {
            try
            {
                var target=Path.Combine(folder,Path.GetFileName(entry.Path));
                if(File.Exists(target))target=Path.Combine(folder,Guid.NewGuid().ToString("N")+".lnk");
                File.Move(entry.Path,target);
                if(File.Exists(entry.Path)||!File.Exists(target))throw new IOException();
                moved.Add(new {original=entry.Path,backup=target});
            }
            catch(Exception e) when(IsRegistrationError(e)){failed++;}
        }
        try {File.WriteAllText(Path.Combine(folder,"restore-map.json"),JsonSerializer.Serialize(moved,new JsonSerializerOptions{WriteIndented=true}));}
        catch(Exception e) when(IsRegistrationError(e)){failed++;}
        return new(failed==0,moved.Count,$"已停用 {moved.Count} 个旧网页监控启动项；快捷方式已备份到 {folder}"+
            (failed>0 ? "；部分项目处理失败，请检查 Windows 启动文件夹权限" : ""));
    }
}
