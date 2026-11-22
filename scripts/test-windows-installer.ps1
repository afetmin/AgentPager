#Requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$Setup,
    [Parameter(Mandatory)] [string]$Portable,
    [Parameter(Mandatory)] [string]$Version,
    [Parameter(Mandatory)] [string]$Commit,
    [Parameter(Mandatory)] [string]$Evidence,
    [Parameter(Mandatory)] [string]$Logs,
    [switch]$DisposableProfile
)

$ErrorActionPreference = 'Stop'
if (-not $IsWindows -or -not $DisposableProfile) { throw 'Use only a disposable Windows VM/profile.' }
if (Get-Process -Name AgentPagerBridge -ErrorAction SilentlyContinue) { throw 'A Bridge is already running.' }

$forkKey = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\{02EB8B83-FD7F-4A1F-892F-7B3B8DF1A49E}_is1'
$upstreamKey = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\{9EAE3F9B-AE27-4B2B-B19E-43AA4E078B07}_is1'
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$profiles = @('HKCU:', 'HKLM:')
foreach ($hive in $profiles) {
    foreach ($key in @($forkKey, $upstreamKey)) {
        if (Test-Path -LiteralPath "$hive\$key") { throw "Existing installation on $hive; use a clean profile." }
    }
}
if (Get-ItemProperty -LiteralPath $runKey -Name AgentPager -ErrorAction SilentlyContinue) {
    throw 'Existing startup settings; use a clean profile.'
}
$shortcut = Join-Path ([Environment]::GetFolderPath('Programs')) 'AgentPager Extension\AgentPager Bridge.lnk'
if (Test-Path -LiteralPath $shortcut) { throw 'Existing shortcut; use a clean profile.' }

function Invoke-Installer([string]$File, [string[]]$Arguments, [string]$Log) {
    # Inno can spawn a second process on uninstall; -Wait waits for the tree.
    $process = Start-Process -FilePath $File -ArgumentList ($Arguments + "/LOG=`"$Log`"") -PassThru -Wait
    if ($process.ExitCode -ne 0) { throw "$File returned $($process.ExitCode); see $Log" }
}
function Hash([string]$File) { (Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash.ToLowerInvariant() }

$work = Join-Path ([IO.Path]::GetTempPath()) ("AgentPager smoke " + [guid]::NewGuid())
$installed = Join-Path $work 'Installed'
$expanded = Join-Path $work 'Portable'
$bridge = Join-Path $installed 'AgentPagerBridge.exe'
$uninstaller = Join-Path $installed 'unins000.exe'
$sentinel = Join-Path $installed 'test-user-file.txt'
$shared = 'agentpager fixture: preserve uninstall ownership boundaries'
New-Item -ItemType Directory -Path $work, $Logs | Out-Null
$runKeyExisted = Test-Path -LiteralPath $runKey
try {
    Expand-Archive -LiteralPath $Portable -DestinationPath $expanded
    if (-not $runKeyExisted) { New-Item -Path $runKey | Out-Null }
    New-ItemProperty -LiteralPath $runKey -Name AgentPager -Value $shared -PropertyType String | Out-Null
    $quiet = @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART')
    Invoke-Installer $Setup ($quiet + @('/SP-', '/NOCLOSEAPPLICATIONS', '/RESTARTEXITCODE=42', "/DIR=`"$installed`"")) `
        (Join-Path $Logs 'install.log')
    $entry = Get-ItemProperty -LiteralPath "HKCU:\$forkKey"
    if ($entry.DisplayName -ne 'AgentPager Bridge (Unofficial Extension)' -or
        $entry.DisplayVersion -cne $Version -or
        $entry.UninstallString -notin @($uninstaller, "`"$uninstaller`"") -or
        -not (Test-Path -LiteralPath $uninstaller -PathType Leaf) -or
        -not (Test-Path -LiteralPath $shortcut -PathType Leaf) -or
        (Test-Path -LiteralPath "HKLM:\$forkKey")) {
        throw 'Missing/wrong per-user Apps & Features entry, uninstaller or shortcut.'
    }
    $installedHash = Hash $bridge
    foreach ($file in Get-ChildItem -LiteralPath $expanded -File -Recurse) {
        $relative = [IO.Path]::GetRelativePath($expanded, $file.FullName)
        if ((Hash $file.FullName) -ne (Hash (Join-Path $installed $relative))) {
            throw "Installed payload differs from portable archive: $relative"
        }
    }
    Set-Content -LiteralPath $sentinel -Value $shared -NoNewline
    Invoke-Installer $uninstaller $quiet (Join-Path $Logs 'uninstall.log')
    foreach ($path in @($bridge, $uninstaller, $shortcut, "HKCU:\$forkKey")) {
        if (Test-Path -LiteralPath $path) { throw "Uninstall left an installer-owned entry: $path" }
    }
    foreach ($file in Get-ChildItem -LiteralPath $expanded -File -Recurse) {
        if (Test-Path -LiteralPath (Join-Path $installed ([IO.Path]::GetRelativePath($expanded, $file.FullName)))) {
            throw "Uninstall left an installed payload entry: $($file.Name)"
        }
    }
    if ((Get-Content -LiteralPath $sentinel -Raw) -cne $shared -or
        (Get-ItemPropertyValue -LiteralPath $runKey -Name AgentPager) -cne $shared -or
        (Test-Path -LiteralPath "HKCU:\$upstreamKey") -or
        (Get-Process -Name AgentPagerBridge -ErrorAction SilentlyContinue)) {
        throw 'Setup/uninstall altered unrelated state or launched the Bridge unexpectedly.'
    }
    [ordered]@{
        schema = 1
        commit = $Commit
        version = $Version
        install_uninstall_passed = $true
        installed_bridge_sha256 = $installedHash
        assets = [ordered]@{
            'AgentPager-Windows-Setup.exe' = (Hash $Setup)
            'AgentPager-Windows-Portable.zip' = (Hash $Portable)
        }
    } | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $Evidence -Encoding utf8NoBOM
    Write-Host 'Native install/uninstall, portable parity, and startup/user-file preservation passed.'
} catch {
    Get-ChildItem -LiteralPath $Logs -File | ForEach-Object { Get-Content -LiteralPath $_.FullName -Tail 100 }
    throw
} finally {
    if ((Get-ItemPropertyValue -LiteralPath $runKey -Name AgentPager -ErrorAction SilentlyContinue) -ceq $shared) {
        Remove-ItemProperty -LiteralPath $runKey -Name AgentPager
    }
    Remove-Item -LiteralPath $work -Recurse -Force
}
