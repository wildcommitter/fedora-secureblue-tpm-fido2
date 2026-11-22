# Install vmgui-agent in a Windows 11 VM (run in an elevated PowerShell, from the
# unpacked vmgui-agent-win11-<arch> folder):
#
#   .\install.ps1 -Cid 7 [-User <name>] [-Fps 15]
#
# -Cid is the VM's vsock CID from `vmgui list` on the host. Needs virtio-win's
# viosock driver (the vsock device from `vmgui xml`). The agent runs at logon in
# the user's interactive session, because capture and SendInput only work there,
# and as the user (not elevated): windows of elevated apps don't take its input.
param(
    [Parameter(Mandatory = $true)][ValidateRange(3, 1000000)][int]$Cid,
    [string]$User = $env:USERNAME,
    [ValidateRange(1, 60)][int]$Fps = 15
)
$ErrorActionPreference = 'Stop'

$exe = Join-Path $PSScriptRoot 'vmgui-agent.exe'
if (-not (Test-Path $exe)) { throw "vmgui-agent.exe is not next to install.ps1" }
if (-not (Get-PnpDevice -FriendlyName '*VirtIO Socket*' -ErrorAction SilentlyContinue)) {
    Write-Warning 'No VirtIO Socket device: install virtio-win (viosock) and add the vsock device (vmgui xml <vm>).'
}
$dir = Join-Path $env:ProgramFiles 'vmgui'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
Copy-Item -Force $exe $dir
$action = New-ScheduledTaskAction -Execute (Join-Path $dir 'vmgui-agent.exe') -Argument "-cid $Cid -fps $Fps"
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $User
$principal = New-ScheduledTaskPrincipal -UserId $User -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit 0 -RestartCount 999 `
    -RestartInterval (New-TimeSpan -Minutes 1) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -Force -TaskName 'vmgui-agent' -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings | Out-Null
Write-Host "vmgui-agent installed for $User (CID $Cid). Log out and in, or: Start-ScheduledTask vmgui-agent"
