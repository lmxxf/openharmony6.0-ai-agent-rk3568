# Settings HAP 编译脚本 (PowerShell)
# 用法: .\build.ps1

$ErrorActionPreference = "Stop"

Write-Host "=== 编译 Settings HAP ===" -ForegroundColor Cyan

# 清理旧构建
if (Test-Path "product\phone\build") {
    Write-Host "清理旧构建..." -ForegroundColor Yellow
    Remove-Item -Recurse -Force "product\phone\build"
}

# 编译
Write-Host "开始编译..." -ForegroundColor Green
.\hvigorw.bat assembleHap --mode module -p product=default -p module=phone

if ($LASTEXITCODE -eq 0) {
    $hapPath = "product\phone\build\default\outputs\default\phone-default-signed.hap"
    if (Test-Path $hapPath) {
        Write-Host "`n=== 编译成功 ===" -ForegroundColor Green
        Write-Host "HAP 路径: $hapPath"
        Write-Host "`n安装命令: hdc install $hapPath"
    }
} else {
    Write-Host "`n=== 编译失败 ===" -ForegroundColor Red
    exit 1
}
