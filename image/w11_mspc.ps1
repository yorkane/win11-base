# w11_mspc.ps1 -- deploy/refresh midscene-pc in the guest and keep its API server running.
# Pushed by win11-inject (base64) and run once per container start via a one-shot
# w11Mspc task (Interactive/Highest: needs the console session for window APIs + screenshots,
# and full admin rights for C:\mspc and Program Files).
##
# All settings come from C:\ProgramData\w11\mspc-args.json (written by the
# injector). No command-line arguments on purpose: values would have to survive four
# escaping layers (bash -> scheduled-task XML -> cmd -> PowerShell) and quietly corrupt.
param([string]$ArgsFile = 'C:\ProgramData\w11\mspc-args.json')
if (-not (Test-Path $ArgsFile)) { Write-Output 'MSPC_ARGS_MISSING'; exit 1 }
$cfg = Get-Content $ArgsFile -Raw | ConvertFrom-Json
$Tar = $cfg.tar; $Version = [string]$cfg.version
if (-not $Version) { $Version = 'v1' }
$Token = [string]$cfg.token; $Gateway = [string]$cfg.gateway; $Key = [string]$cfg.key
$Model = [string]$cfg.model; if (-not $Model) { $Model = 'gpt-5.6-luna' }
$Family = [string]$cfg.family; if (-not $Family) { $Family = 'gpt-5' }
$ErrorActionPreference = 'Continue'
$root = 'C:\mspc'
$pdir = 'C:\ProgramData\w11'
$log  = $pdir + '\mspc-deploy.log'
function Log($m) { $line = (Get-Date -Format 'HH:mm:ss') + ' ' + $m; Add-Content -Path $log -Value $line; Write-Output $line }
New-Item -ItemType Directory -Path $pdir -Force | Out-Null
Log ('=== mspc deploy ' + $Version + ' ===')

$cur = ''
if (Test-Path ($root + '\.mspc-version')) { $cur = (Get-Content ($root + '\.mspc-version') -First 1).Trim() }
# Re-install not only on version drift but also when the marker lies (node.exe gone).
if ($Tar -and (Test-Path $Tar) -and (($cur -ne $Version) -or -not (Test-Path ($root + '\bin\node.exe')))) {
  Log ('installing payload (' + $cur + ' -> ' + $Version + ')')
  $tmp = $pdir + '\mspc-unpack'
  if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
  New-Item -ItemType Directory -Path $tmp -Force | Out-Null
  tar.exe -xzf $Tar -C $tmp
  Log ('UNPACK_EXIT=' + $LASTEXITCODE)
  if (Test-Path $root) {
    $old = $root + '.old'
    if (Test-Path $old) { Remove-Item $old -Recurse -Force -ErrorAction Continue }
    Move-Item $root $old -Force
  }
  Move-Item ($tmp + '\mspc') $root -Force
  # node.exe lives INSIDE C:\mspc\bin, not C:\Program Files. The deploy task carries the
  # user's UAC-filtered token: creating a dir under C:\Program Files fails there as a
  # NON-terminating error that try/catch does NOT catch, so the old code logged
  # 'node.exe updated' while nothing actually landed (2026-09-05). C:\mspc sits on the
  # volume root, where Built-in Users may create and write, and nothing else needs node.
  $want = $root + '\bin\node.exe'
  New-Item -ItemType Directory -Path ($root + '\bin') -Force | Out-Null
  $new  = $tmp + '\node.exe'
  if (Test-Path $new) {
    $hw = ''; if (Test-Path $want) { $hw = (Get-FileHash $want -ErrorAction SilentlyContinue).Hash }
    if ((Get-FileHash $new).Hash -ne $hw) {
      Stop-Process -Name node -Force -ErrorAction SilentlyContinue
      Move-Item $new $want -Force -ErrorAction SilentlyContinue
      # Trust no log line: verify the file is really there before claiming success.
      if (Test-Path $want) { Log 'node.exe updated' } else { Log 'ERROR: node.exe did not land'; Write-Output 'MSPC_DEPLOY_FAILED'; exit 1 }
    } else { Log 'node.exe identical' }
  } elseif (-not (Test-Path $want)) { Log 'ERROR: payload carries no node.exe'; Write-Output 'MSPC_DEPLOY_FAILED'; exit 1 }
  Remove-Item $tmp -Recurse -Force -ErrorAction Continue
  Remove-Item $Tar -Force -ErrorAction Continue
  Set-Content -Path ($root + '\.mspc-version') -Value $Version -Encoding ASCII
  Log 'payload installed'
} elseif (Test-Path $Tar) { Log 'payload up to date'; Remove-Item $Tar -Force -ErrorAction Continue }
elseif ($cur -eq $Version) { Log 'payload up to date (not re-pushed)' }
else { Log 'ERROR: payload missing but version differs'; Write-Output 'MSPC_DEPLOY_FAILED'; exit 1 }

# .env: manage only our keys; preserve operator-set ones.
$envFile = $root + '\.env'
$cur2 = @{}
if (Test-Path $envFile) { Get-Content $envFile | ForEach-Object { $i = $_.IndexOf('='); if ($i -gt 0) { $cur2[$_.Substring(0,$i)] = $_.Substring($i+1) } } }
$cur2['PORT'] = '3333'
if ($Token) { $cur2['TOKEN'] = $Token; $cur2['HOST'] = '0.0.0.0' } else { $cur2['HOST'] = '127.0.0.1'; Log 'WARNING no token: bound to 127.0.0.1' }
if ($Gateway) {
  $cur2['MIDSCENE_MODEL_BASE_URL'] = $Gateway
  $cur2['MIDSCENE_MODEL_NAME'] = $Model
  $cur2['MIDSCENE_MODEL_FAMILY'] = $Family
  $cur2['MIDSCENE_MODEL_API_KEY'] = $Key
}
# Compare before/after so a token or gateway rotation is noticed: the launcher reads
# .env only at startup, so an already-listening server keeps answering with the OLD
# token forever unless it is restarted (verified 2026-09-05: old token 200, new 401).
$envBefore = ''
if (Test-Path $envFile) { $envBefore = (Get-Content $envFile -Raw) }
$lines = @(); foreach ($k in ($cur2.Keys | Sort-Object)) { $lines += ($k + '=' + $cur2[$k]) }
Set-Content -Path $envFile -Value $lines -Encoding ASCII
$envChanged = ((Get-Content $envFile -Raw) -ne $envBefore)
Log ('env keys=' + $cur2.Count + ' changed=' + $envChanged)

# Launch script + AtLogOn Interactive task = the Windows service equivalent (session 0
# services cannot enumerate windows or take console screenshots; never move this to SYSTEM).
$launch = $pdir + '\mspc_server.ps1'
$ls = @(
  'Set-Location C:\mspc',
  # PORT/HOST come from C:\mspc\.env (dotenv keeps process env, so a hard-coded
  # value here would silently override the token-binding rule in .env).
  # If node.exe vanished (volume wiped by hand), exit 9 so Task History tells the story.
  'if (-not (Test-Path ''C:\mspc\bin\node.exe'')) { exit 9 }',
  '& ''C:\mspc\bin\node.exe'' dist/win-node-app.js *>> C:\ProgramData\w11\mspc-server.log'
)
Set-Content -Path $launch -Value $ls -Encoding ASCII
$act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ' + $launch)
$pri = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest
$trg = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit (New-TimeSpan -Seconds 0)
$null = Register-ScheduledTask -TaskName mspcServer -Action $act -Principal $pri -Trigger $trg -Settings $set -Force
$running = Get-NetTCPConnection -LocalPort 3333 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
if ($running -and $envChanged) {
  # Recycle: stop the task AND its node child (stopping the task alone leaves the
  # child listening with the old environment), then start it again fresh.
  Stop-ScheduledTask -TaskName mspcServer -ErrorAction SilentlyContinue
  Stop-Process -Name node -Force -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 2
  Start-ScheduledTask -TaskName mspcServer
  Log 'server restarted (env changed)'
} elseif (-not $running) { Start-ScheduledTask -TaskName mspcServer; Log 'server started via task' } else { Log 'server already listening' }
Start-Sleep -Seconds 6
$ok = Get-NetTCPConnection -LocalPort 3333 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
# The injector polls this log for the verdict: stdout of a scheduled task goes nowhere,
# so every final line must live in the log file too.
if ($ok) { $msg = 'MSPC_API=' + $ok.LocalAddress + ':3333 UP' } else { $msg = 'MSPC_API=DOWN' }
Log $msg
Log 'MSPC_DEPLOY_DONE'
Write-Output $msg
Write-Output 'MSPC_DEPLOY_DONE'
