# vda_install.ps1 -- install the SPICE vdagent guest components so that QEMU can bridge
# the VNC (noVNC) clipboard to the Windows console clipboard. Pushed by win11-inject.
#
# Preconditions (all owned by the container, NOT this script):
#   - QEMU cold-plugged: -chardev qemu-vdagent,...,clipboard=on + virtio-serial-pci +
#     virtserialport,name=com.redhat.spice.0  (q35 refuses hotplug, so this comes from
#     the ARGUMENTS env of the container; without it the driver installs but never links)
#   - payload tarball at C:/ProgramData/w11/vda-payload.tar.gz (base64-pushed by injector)
# All settings come from the JSON sidecar pattern used by w11_mspc.ps1 is NOT needed here:
# there are zero operator values. Everything is idempotent: re-running only fixes drift.
$ErrorActionPreference = 'Continue'
$pdir = 'C:\ProgramData\w11'
$dst  = 'C:\vdagent'
$tar  = $pdir + '\vda-payload.tar.gz'
$log  = $pdir + '\vda-install.log'
function Log($m) { $line = (Get-Date -Format 'HH:mm:ss') + ' ' + $m; Add-Content -Path $log -Value $line; Write-Output $line }
$ver = ''
if (Test-Path $tar) { $ver = (Get-FileHash $tar).Hash.Substring(0,12) }
New-Item -ItemType Directory -Path $pdir -Force | Out-Null
Log ('=== vda install ===')

# 1. payload must be present unless a previous install already landed (marker).
$marker = $dst + '\.vda-version'
$cur = ''
if (Test-Path $marker) { $cur = (Get-Content $marker -First 1).Trim() }
if (-not (Test-Path $tar)) {
  if ($cur) { Log 'payload absent but marker present -> already installed' }
  else { Log 'ERROR: no payload and no marker'; Write-Output 'VDA_FAILED'; exit 1 }
} elseif ($cur -eq $ver) {
  Log 'payload up to date'
  Remove-Item $tar -Force -ErrorAction SilentlyContinue
} else {
  $tmp = $pdir + '\vda-unpack'
  if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
  New-Item -ItemType Directory -Path $tmp -Force | Out-Null
  tar.exe -xzf $tar -C $tmp
  Log ('UNPACK_EXIT=' + $LASTEXITCODE)
  # C:dagent lives on the volume root: writable with the UAC-filtered interactive
  # token (Program Files is NOT -- see the node.exe lesson).
  New-Item -ItemType Directory -Path $dst -Force | Out-Null
  Copy-Item ($tmp + '\*') $dst -Recurse -Force
  Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item $tar -Force -ErrorAction SilentlyContinue
  if (-not (Test-Path ($dst + '\vdservice.exe'))) { Log 'ERROR: vdservice.exe did not land'; Write-Output 'VDA_FAILED'; exit 1 }
  Set-Content -Path $marker -Value $ver -Encoding ASCII
  Log 'payload installed'
}

# 2. vioserial driver: binds PCI VEN_1AF4&DEV_1003, creates vport0p1 and the
#    \\.\Global\com.redhat.spice.0 symlink vdagent talks through.
$inf = $dst + '\vioserial\vioser.inf'
$needDrv = $true
$dev = Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -like '*VEN_1AF4&DEV_1003*' }
if ($dev -and ($dev.Status -eq 'OK')) { $needDrv = $false; Log 'driver already bound' }
if ($needDrv) {
  $pnp = pnputil /add-driver $inf /install 2>&1
  Log ('PNPUTIL_EXIT=' + $LASTEXITCODE + ' last=' + (($pnp | Select-Object -Last 1) -replace '\s+',' '))
  Start-Sleep -Seconds 4
}
$dev = Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -like '*VEN_1AF4&DEV_1003*' }
if ($dev) { $dev | ForEach-Object { Log ('DEV(' + $_.FriendlyName + ') status=' + $_.Status) } } else { Log 'WARN: virtio-serial device absent (QEMU ARGUMENTS missing?)' }
# The \.Global device namespace is invisible to the FileSystem provider; open it through
# .NET instead. Diagnostic only -- a missing link here does NOT decide the verdict.
try {
  $fs = [System.IO.File]::Open('\\\\.\\Global\\com.redhat.spice.0', 'Open', 'ReadWrite', 'None')
  $fs.Close(); Log 'VPORT_LINK=openable'
} catch { Log ('VPORT_LINK=not-openable: ' + $_.Exception.GetType().Name) }

# 3. vdservice: the service spawns vdagent.exe into the console session (session 1),
#    which is where the interactive clipboard lives. Real service name: vdservice.
$svc = Get-Service -Name 'vdservice' -ErrorAction SilentlyContinue
if (-not $svc) {
  $out = & ($dst + '\vdservice.exe') install 2>&1
  Log ('INSTALL_OUT=' + (($out | Out-String) -replace '[\r\n]+', ';'))
  $svc = Get-Service -Name 'vdservice' -ErrorAction SilentlyContinue
}
if (-not $svc) { Log 'ERROR: vdservice not registered'; Write-Output 'VDA_FAILED'; exit 1 }
$null = & sc.exe config vdservice start= auto 2>&1
if ($svc.Status -ne 'Running') { Start-Service vdservice -ErrorAction SilentlyContinue; Log 'service started' }
# The driver often becomes ready only AFTER the service's first connect attempt; one
# unconditional restart makes vdagent re-open the vport (verified 2026-09-04 on win11-wx).
Restart-Service vdservice -ErrorAction SilentlyContinue
Start-Sleep -Seconds 3
$svc = Get-Service -Name 'vdservice'
$proc = @(Get-Process -Name vdagent -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -ne 0 })
# The injector polls THIS log file, not stdout (a scheduled task's stdout goes nowhere):
# every machine-readable verdict token must be Log-ed verbatim -- same rule as mspc.
if ($svc.Status -eq 'Running' -and $proc.Count -ge 1) {
  Log ('VDA_AGENT_UP sess=' + ($proc | Select-Object -First 1).SessionId)
  Write-Output 'VDA_AGENT_UP'
} else {
  Log ('VDA_AGENT_DOWN svc=' + $svc.Status + ' procs=' + $proc.Count)
  Write-Output 'VDA_AGENT_DOWN'
}
