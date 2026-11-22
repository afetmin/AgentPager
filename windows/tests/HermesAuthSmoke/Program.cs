using System.Diagnostics;
using AgentPager.Core;
var root = Path.Combine(Path.GetTempPath(), "agentpager-auth-" + Guid.NewGuid().ToString("N"));
if (Environment.GetEnvironmentVariable("AGENTPAGER_AUTH_TEST_ROOT") is null)
{
    Directory.CreateDirectory(root);
    var start = new ProcessStartInfo(Environment.ProcessPath!) { UseShellExecute = false };
    if (Path.GetFileNameWithoutExtension(Environment.ProcessPath) == "dotnet") start.ArgumentList.Add(typeof(HermesAuthTests).Assembly.Location);
    start.Environment["AGENTPAGER_AUTH_TEST_ROOT"] = root;
    start.Environment["XDG_DATA_HOME"] = Path.Combine(root, "profile");
    start.Environment["HOME"] = Path.Combine(root, "home");
    Directory.CreateDirectory(start.Environment["XDG_DATA_HOME"]!);
    Directory.CreateDirectory(start.Environment["HOME"]!);
    try { using var child = Process.Start(start)!; await child.WaitForExitAsync(); return child.ExitCode; }
    finally { Directory.Delete(root, true); }
}
if (!AgentPagerPaths.DataRoot.StartsWith(Environment.GetEnvironmentVariable("AGENTPAGER_AUTH_TEST_ROOT")!, StringComparison.Ordinal)) throw new Exception("Unisolated auth fixture");
await HermesAuthTests.Run();
return 0;
