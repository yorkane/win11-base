# w11_retire.ps1 -- remove the midscene-pc leftovers that the seed disk was baked with.
# Runs as a SYSTEM one-shot task: the UAC-filtered SSH token cannot unregister another
# user's logon task, delete C:\mspc, or touch the firewall (the OpenSSH-capability and
# driver-install lesson). Idempotent: every statement tolerates absence.
# This script performs the removal and only RECORDS that it did it. Verifying from inside
# this process is unreliable: the Task Scheduler and firewall cmdlets read a provider
# cache that still lists objects moments after removal, and under -ErrorAction
# SilentlyContinue a missing task still pushes one $null through the pipeline, so a
# Measure-Object count reports 1 for something already gone. The injector verifies with a
# separate ssh call whose verdict comes from schtasks exit status, not a cmdlet count.
$ErrorActionPreference = 'SilentlyContinue'
$pdir = 'C:\ProgramData\w11'
function Log($m) { $m | Add-Content (Join-Path $pdir 'retire.log') -ErrorAction SilentlyContinue; Write-Output $m }
Stop-ScheduledTask -TaskName mspcServer
Unregister-ScheduledTask -TaskName mspcServer -Confirm:$false
Unregister-ScheduledTask -TaskName w11Mspc -Confirm:$false
Get-NetFirewallRule | Where-Object { $_.DisplayName -like 'midscene-pc*' } | Remove-NetFirewallRule
if (Test-Path 'C:\mspc') {
  Get-Process node -ErrorAction SilentlyContinue | Stop-Process -Force
  Start-Sleep -Seconds 2
  Remove-Item 'C:\mspc' -Recurse -Force
  Log 'RETIRED pass: stopped node and removed C:\mspc'
}
foreach ($f in @('mspc_server.ps1', 'mspc-args.json', 'mspc-deploy.log', 'mspc-once.log', 'mspc-server.log')) {
  Remove-Item (Join-Path $pdir $f) -Force -ErrorAction SilentlyContinue
}
Log 'RETIRED done'
exit 0
