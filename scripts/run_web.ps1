# 一键：本地代理 + Flutter Web（对齐旧 Veliora「server 带 /proxy」调试方式）
param(
    [int]$WebPort = 8080,
    [int]$ProxyPort = 8091
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$env:Path = "D:\dev\flutter\bin;$env:Path"
$env:PUB_CACHE = "D:\dev\pub-cache"
$env:PROXY_PORT = "$ProxyPort"

Set-Location $Root

# 释放端口
foreach ($p in @($WebPort, $ProxyPort)) {
    Get-NetTCPConnection -LocalPort $p -ErrorAction SilentlyContinue |
        ForEach-Object { Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue }
}

Write-Host "[INFO] 启动本地代理 :$ProxyPort ..." -ForegroundColor Cyan
$proxy = Start-Process -PassThru -WindowStyle Hidden -FilePath "dart" -ArgumentList @(
    "run", "tool/web_proxy.dart"
) -WorkingDirectory $Root
Start-Sleep -Seconds 1
if ($proxy.HasExited) { throw "代理启动失败" }

Write-Host "[INFO] 启动 Flutter Web :$WebPort ..." -ForegroundColor Cyan
Write-Host "浏览器打开 http://localhost:$WebPort" -ForegroundColor Green
try {
    flutter run -d web-server --web-hostname=0.0.0.0 --web-port=$WebPort
} finally {
    if (-not $proxy.HasExited) { Stop-Process -Id $proxy.Id -Force -ErrorAction SilentlyContinue }
}
