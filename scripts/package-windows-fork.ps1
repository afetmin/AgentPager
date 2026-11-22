#Requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidatePattern('^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$')]
    [string]$Version,
    [Parameter(Mandatory)] [string]$OutputDirectory,
    [string]$TermsDirectory,
    [string]$Compiler = $env:INNO_SETUP_COMPILER,
    [switch]$VerifyInDisposableProfile
)

$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'This build requires native Windows with Inno Setup 6.4 or newer.' }
$root = Split-Path -Parent $PSScriptRoot
$out = [IO.Path]::GetFullPath($OutputDirectory)
$python = (Get-Command python.exe -CommandType Application).Source
$dotnet = (Get-Command dotnet.exe -CommandType Application).Source
$packageScript = Join-Path $PSScriptRoot 'package-fork-release.py'
$installerScript = Join-Path $root 'windows/installer/AgentPager.Fork.iss'
$project = Join-Path $root 'windows/src/AgentPager.Bridge/AgentPager.Bridge.csproj'

if (-not $Compiler) {
    $Compiler = @(
        "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
        "$env:ProgramFiles\Inno Setup 6\ISCC.exe",
        "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe"
    ) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
}
if (-not $Compiler -or -not (Test-Path -LiteralPath $Compiler -PathType Leaf)) {
    throw 'Set INNO_SETUP_COMPILER to the full path of ISCC.exe (Inno Setup 6.4+).'
}
$Compiler = (Resolve-Path -LiteralPath $Compiler).Path
if ($TermsDirectory) { $TermsDirectory = (Resolve-Path -LiteralPath $TermsDirectory).Path }
if (Test-Path -LiteralPath $out) { throw "Output path already exists: $out" }
if ($VerifyInDisposableProfile) {
    $status = & git -C $root status --porcelain --untracked-files=normal
    if ($LASTEXITCODE -ne 0 -or $status) { throw 'Native release verification requires a clean Git checkout.' }
}
$commit = & git -C $root rev-parse HEAD
if ($LASTEXITCODE -ne 0) { throw 'Could not identify source commit.' }

$stage = Join-Path (Split-Path -Parent $out) ('.agentpager-windows-' + [guid]::NewGuid())
$publish = Join-Path $stage 'publish'
$payload = Join-Path $stage 'payload'
$assets = Join-Path $stage 'assets'
$setup = Join-Path $assets 'AgentPager-Windows-Setup.exe'
$portable = Join-Path $assets 'AgentPager-Windows-Portable.zip'
New-Item -ItemType Directory -Path $assets -Force | Out-Null
try {
    # Pin SDK selection without changing the upstream checkout or its builds.
    '{"sdk":{"version":"8.0.419","rollForward":"disable"}}' |
        Set-Content -LiteralPath (Join-Path $stage 'global.json') -Encoding utf8NoBOM
    Push-Location $stage
    try {
        $sdk = & $dotnet --version
        if ($LASTEXITCODE -ne 0 -or $sdk -ne '8.0.419') {
            throw 'Install/select .NET SDK 8.0.419 for the verified .NET 8.0.25 notice set.'
        }
        if (-not $TermsDirectory) {
            $TermsDirectory = Join-Path $stage 'terms'
            & $python $packageScript windows-terms --out $TermsDirectory
            if ($LASTEXITCODE -ne 0) { throw 'Could not fetch and verify Windows third-party terms.' }
        }
        $nugetOutput = & $dotnet nuget locals global-packages --list --force-english-output
        if ($LASTEXITCODE -ne 0 -or -not ([string]$nugetOutput -match '^global-packages: (.+)$')) {
            throw 'Could not locate the NuGet global package cache.'
        }
        $nuget = $Matches[1].Trim()
        & $dotnet publish $project -c Release -r win-x64 --self-contained true `
            '-p:PublishSingleFile=true' '-p:PublishTrimmed=false' '-p:DebugType=None' `
            "-p:Version=$Version" -o $publish
        if ($LASTEXITCODE -ne 0) { throw 'dotnet publish failed.' }
        & $python $packageScript windows-payload --exe (Join-Path $publish 'AgentPagerBridge.exe') `
            --terms $TermsDirectory --nuget $nuget --payload $payload --portable $portable
        if ($LASTEXITCODE -ne 0) { throw 'Windows payload generation failed.' }
        & $Compiler "/DAppVersion=$Version" "/DPayloadDir=$payload" "/O$assets" $installerScript
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $setup -PathType Leaf)) {
            throw 'Inno Setup did not produce the installer.'
        }
        if ($VerifyInDisposableProfile) {
            & (Join-Path $PSScriptRoot 'test-windows-installer.ps1') -Setup $setup -Portable $portable `
                -Version $Version -Commit $commit -Evidence (Join-Path $assets 'windows-smoke.json') `
                -Logs (Join-Path $assets 'installer-smoke-logs') -DisposableProfile
            $status = & git -C $root status --porcelain --untracked-files=normal
            if ($LASTEXITCODE -ne 0 -or $status -or $commit -ne (& git -C $root rev-parse HEAD)) {
                throw 'Source checkout changed during the build; use an ignored or external output directory.'
            }
        }
        [IO.Directory]::Move($assets, $out)
    } finally { Pop-Location }
} finally {
    Remove-Item -LiteralPath $stage -Recurse -Force
}
Write-Output $out
