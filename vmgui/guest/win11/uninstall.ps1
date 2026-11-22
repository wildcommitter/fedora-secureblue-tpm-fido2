# Remove vmgui-agent from a Windows 11 VM (elevated PowerShell).
$ErrorActionPreference = 'Stop'
Unregister-ScheduledTask -TaskName 'vmgui-agent' -Confirm:$false -ErrorAction SilentlyContinue
Stop-Process -Name 'vmgui-agent' -Force -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force (Join-Path $env:ProgramFiles 'vmgui') -ErrorAction SilentlyContinue
Write-Host 'vmgui-agent removed.'
