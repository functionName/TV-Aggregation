# TV APK build (default: armeabi-v7a only)
#
#   .\scripts\build_tv_apk.ps1           # release + R8, v7a only
#   .\scripts\build_tv_apk.ps1 -Fast     # skip R8 (faster, larger APK)
#   .\scripts\build_tv_apk.ps1 -AllAbi   # all ABIs (slow)
#
param(
    [switch]$Fast,
    [switch]$AllAbi,
    [switch]$OpenFolder
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$flutter = "D:\dev\flutter\bin\flutter.bat"
if (-not (Test-Path $flutter)) {
    $flutter = "flutter"
}

Write-Host "=== yingshi_daquan TV APK ===" -ForegroundColor Cyan
Write-Host "AllAbi=$AllAbi (minify disabled for TV stability)"
$sw = [System.Diagnostics.Stopwatch]::StartNew()

$buildArgs = @("build", "apk", "--release")
if ($AllAbi) {
    $buildArgs += "--split-per-abi"
} else {
    # Pure 32-bit APK for old TVs (do not combine with ndk abiFilters)
    $buildArgs += @("--split-per-abi", "--target-platform", "android-arm")
}

& $flutter @buildArgs
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$sw.Stop()
$outDir = Join-Path $root "build\app\outputs\flutter-apk"
$version = "unknown"
try {
    $line = Select-String -Path (Join-Path $root "pubspec.yaml") -Pattern "^version:\s*(.+)$" | Select-Object -First 1
    if ($line) { $version = ($line.Matches[0].Groups[1].Value -split "\+")[0].Trim() }
} catch {}

$src = Join-Path $outDir "app-armeabi-v7a-release.apk"
if (-not (Test-Path $src)) {
    $alt = Join-Path $outDir "app-release.apk"
    if (Test-Path $alt) { $src = $alt }
}
if (-not (Test-Path $src)) {
    Write-Host "APK not found in $outDir" -ForegroundColor Red
    exit 1
}

$tag = if ($Fast) { "fast" } else { "release" }
$dstName = "yingshi-$version-armeabi-v7a-$tag.apk"
$dst = Join-Path $outDir $dstName
Copy-Item $src $dst -Force

Write-Host ""
Write-Host ("Elapsed: {0:n1}s" -f $sw.Elapsed.TotalSeconds) -ForegroundColor Green
Write-Host "Output: $dst"
Get-Item $dst | Format-List Name, Length, FullName

if ($OpenFolder) {
    explorer.exe $outDir
}
