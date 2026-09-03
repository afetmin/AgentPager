[CmdletBinding()]
param(
    [string]$Version = $(if ($env:AGENTPAGER_VERSION_NAME) { $env:AGENTPAGER_VERSION_NAME } else { "0.3.1" }),
    [string]$Configuration = "Release"
)

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$project = Join-Path $projectRoot "windows\src\AgentPager.Bridge\AgentPager.Bridge.csproj"
$publishDirectory = Join-Path $projectRoot "dist\windows-publish"
$outputDirectory = Join-Path $projectRoot "dist"
$dotnetCommand = Get-Command dotnet.exe -ErrorAction SilentlyContinue
$dotnet = if ($dotnetCommand) {
    $dotnetCommand.Source
} else {
    Join-Path $env:ProgramFiles "dotnet\dotnet.exe"
}
if (-not (Test-Path $dotnet)) {
    throw ".NET SDK was not found."
}

if (Test-Path $publishDirectory) {
    Remove-Item $publishDirectory -Recurse -Force
}
New-Item $publishDirectory -ItemType Directory -Force | Out-Null
New-Item $outputDirectory -ItemType Directory -Force | Out-Null

$publishArguments = @(
    "publish",
    "`"$project`"",
    "-c", $Configuration,
    "-r", "win-x64",
    "--self-contained", "true",
    "-p:PublishSingleFile=true",
    "-p:PublishTrimmed=false",
    "-p:Version=$Version",
    "-o", "`"$publishDirectory`""
) -join " "
$publish = Start-Process -FilePath $dotnet -ArgumentList $publishArguments -NoNewWindow -Wait -PassThru
if ($publish.ExitCode -ne 0) {
    throw "dotnet publish failed"
}

$compilerCandidates = @(
    $env:INNO_SETUP_COMPILER,
    "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe",
    "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
    "$env:ProgramFiles\Inno Setup 6\ISCC.exe"
) | Where-Object { $_ -and (Test-Path $_) }
$compiler = $compilerCandidates | Select-Object -First 1
if (-not $compiler) {
    throw "Inno Setup 6 was not found. Install it with: winget install --id JRSoftware.InnoSetup"
}

$installerScript = Join-Path $projectRoot "windows\installer\AgentPager.iss"
$innoArguments = @(
    "/DAppVersion=$Version",
    "`"/DPublishDir=$publishDirectory`"",
    "`"/O$outputDirectory`"",
    "`"$installerScript`""
) -join " "
$inno = Start-Process -FilePath $compiler -ArgumentList $innoArguments -NoNewWindow -Wait -PassThru
if ($inno.ExitCode -ne 0) {
    throw "Inno Setup compilation failed"
}

Write-Output (Join-Path $outputDirectory "AgentPager-Windows-Setup.exe")
