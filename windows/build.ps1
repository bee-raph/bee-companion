param(
    [ValidateSet("x64", "ARM64")][string]$Architecture = "x64",
    [ValidateSet("Debug", "Release")][string]$Configuration = "Release",
    [string]$InstanceConfigurationPath = ""
)
$ErrorActionPreference = "Stop"
if ($env:OS -ne "Windows_NT") { throw "WinUI XAML compilation requires Windows. Run this script on a Windows machine." }
$root = $PSScriptRoot
$outputRoot = if ($env:BeeBuildRoot) { $env:BeeBuildRoot } else { $root }
$runtime = if ($Architecture -eq "ARM64") { "win-arm64" } else { "win-x64" }
& dotnet test "$root/Companion.Core.Tests/Companion.Core.Tests.csproj" -c $Configuration
if ($LASTEXITCODE -ne 0) { throw "Core tests failed." }
$deploymentProperties = @()
if ($InstanceConfigurationPath) {
    $instancePath = (Resolve-Path $InstanceConfigurationPath).Path
    $deploymentProperties += "-p:InstanceConfigurationPath=$instancePath"
}
& dotnet publish "$root/Companion.Windows/Companion.Windows.csproj" -c $Configuration -r $runtime `
    -p:Platform=$Architecture @deploymentProperties --self-contained true -o "$outputRoot/dist/$runtime"
if ($LASTEXITCODE -ne 0) { throw "Native Windows build failed. See the compiler diagnostics above." }
if (-not (Test-Path "$outputRoot/dist/$runtime/Companion.Windows.pri")) {
    throw "Published WinUI application resources are missing; the app would fail on startup."
}
Write-Host "Built: $outputRoot/dist/$runtime/Companion.Windows.exe"
