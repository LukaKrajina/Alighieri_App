# Windows 构建需要创建插件符号链接。没有开启开发者模式时，
# 用管理员权限运行本脚本即可，不需要改系统设置，省一次重启、也省一次翻设置。
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$flutterBin = "C:\SDK\flutter\bin"
if (-not (Test-Path (Join-Path $flutterBin "flutter.bat"))) {
  $flutterBin = Split-Path -Parent (Get-Command flutter.cmd).Source
}
$env:Path = "$flutterBin;" + $env:Path
Set-Location $root
& flutter build windows --release *> (Join-Path $root "build_windows.log")
exit $LASTEXITCODE