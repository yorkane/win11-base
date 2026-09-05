#!/usr/bin/env bash
# win11-inject.sh -- push deploy-time settings into the pre-installed Windows guest.
#
# No secret is baked into the image: everything comes from the container environment
# at `docker run` time and is applied over the guest's own SSH as soon as it is up.
#
#   WIN11_USER           local account name (renames the account on the sealed disk)
#   WIN11_PASSWORD       local account password
#   WIN11_KMS            KMS host[:port] to activate against
#   WIN11_KMS_KEY        optional KMS client setup key for that host
#   WIN11_INIT_USER      account name currently on the disk (default: aigc)
#   WIN11_INIT_PASSWORD  password currently on the disk (default: aigc)
#   WIN11_GUEST_IP       skip discovery and use this address
#   WIN11_INJECT_TIMEOUT seconds to wait for the guest (default: 900)
#   WIN11_DESKTOP        off -> keep the stock desktop (icons + taskbar visible)
#   WIN11_MSPC           off -> skip the midscene-pc API server (default: on if payload present)
#   WIN11_MSPC_TOKEN     token for the API on :3333. Empty = bind guest loopback only.
#   WIN11_MSPC_GATEWAY / WIN11_MSPC_MODEL_KEY / WIN11_MSPC_MODEL / WIN11_MSPC_FAMILY
#                        model backend for AI endpoints (window APIs need none of these)
#
# The sealed disk carries a well-known initial credential, exactly like dockur ships
# admin/admin: its only job is to let this script rotate it on first boot.
set -u
trap 'exit 0' TERM INT

INIT_USER="${WIN11_INIT_USER:-aigc}"
INIT_PASSWORD="${WIN11_INIT_PASSWORD:-aigc}"
DESIRED_USER="${WIN11_USER:-}"
DESIRED_PASSWORD="${WIN11_PASSWORD:-}"
KMS_HOST="${WIN11_KMS:-}"
KMS_KEY="${WIN11_KMS_KEY:-}"
GUEST_IP="${WIN11_GUEST_IP:-}"
TIMEOUT="${WIN11_INJECT_TIMEOUT:-900}"

say() { printf '> win11-inject: %s\n' "$1"; }

# The desktop look (black background, no icons, auto-hidden taskbar) is applied on
# every start unless the deployer opts out; credentials and KMS stay opt-in.
DESKTOP="${WIN11_DESKTOP:-on}"
MSPC="${WIN11_MSPC:-on}"
MSPC_TOKEN="${WIN11_MSPC_TOKEN:-}"
MSPC_GATEWAY="${WIN11_MSPC_GATEWAY:-}"
MSPC_MODEL_KEY="${WIN11_MSPC_MODEL_KEY:-}"
MSPC_MODEL="${WIN11_MSPC_MODEL:-gpt-5.6-luna}"
MSPC_FAMILY="${WIN11_MSPC_FAMILY:-gpt-5}"

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
SSH_OPTS="$SSH_OPTS -o ConnectTimeout=10 -o PreferredAuthentications=password"
SSH_OPTS="$SSH_OPTS -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1"

guest_ip() {
  local ip=""
  if [ -n "$GUEST_IP" ]; then printf '%s' "$GUEST_IP"; return; fi
  if [ -s /var/lib/misc/dnsmasq.leases ]; then
    ip=$(awk 'NF>=4 {print $3; exit}' /var/lib/misc/dnsmasq.leases)
  fi
  if [ -z "$ip" ]; then
    ip=$(ip -o neigh show dev docker 2>/dev/null | awk '{print $1; exit}')
  fi
  printf '%s' "$ip"
}

tcp_open() { timeout 3 bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null; }

wait_for_guest() {
  local waited=0 ip=""
  while [ "$waited" -lt "$TIMEOUT" ]; do
    ip=$(guest_ip)
    if [ -n "$ip" ] && tcp_open "$ip" 22; then printf '%s' "$ip"; return 0; fi
    sleep 3
    waited=$((waited+3))
  done
  return 1
}

# PowerShell reads a script from stdin; the guest expects CRLF line endings.
ps_run() {
  local user="$1" password="$2" ip="$3" script="$4" rc=0
  local out
  out=$(printf '%s' "$script" | awk '{printf "%s\r\n", $0}' |
    sshpass -p "$password" ssh -p 22 $SSH_OPTS "$user@$ip" \
      'powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command -' 2>&1)
  rc=$?
  # Guest output arrives with CRLF; command substitution keeps the CR, which silently
  # breaks exact string comparisons such as the activation check below.
  printf '%s\n' "$out" | tr -d '\r'
  return $rc
}

# ---------------------------------------------------------------- credentials
PROBE='Write-Output ("USER=" + [Security.Principal.WindowsIdentity]::GetCurrent().Name)'

probe_cred() {
  local user="$1" password="$2" out
  out=$(ps_run "$user" "$password" "$IP" "$PROBE") || return 1
  printf '%s' "$out" | grep -q '^USER='
}

say "waiting for the guest to boot and offer SSH ..."
IP=$(wait_for_guest) || { say "ERROR: guest SSH never became reachable (set WIN11_GUEST_IP?)"; exit 1; }
say "guest SSH reachable at $IP"

say "probing credentials on the sealed disk ..."
CUR_USER=""; CUR_PASS=""
if probe_cred "$INIT_USER" "$INIT_PASSWORD"; then
  CUR_USER="$INIT_USER"; CUR_PASS="$INIT_PASSWORD"
elif [ -n "$DESIRED_USER" ] && [ -n "$DESIRED_PASSWORD" ] && probe_cred "$DESIRED_USER" "$DESIRED_PASSWORD"; then
  CUR_USER="$DESIRED_USER"; CUR_PASS="$DESIRED_PASSWORD"
elif [ -n "$DESIRED_USER" ] && probe_cred "$DESIRED_USER" "$INIT_PASSWORD"; then
  CUR_USER="$DESIRED_USER"; CUR_PASS="$INIT_PASSWORD"
elif [ -n "$DESIRED_PASSWORD" ] && probe_cred "$INIT_USER" "$DESIRED_PASSWORD"; then
  CUR_USER="$INIT_USER"; CUR_PASS="$DESIRED_PASSWORD"
fi

if [ -z "$CUR_USER" ]; then
  say "ERROR: no known credential works on this volume."
  say "       pass the credential currently on the disk via WIN11_INIT_USER / WIN11_INIT_PASSWORD."
  exit 1
fi
say "authenticated as $CUR_USER"

# Values reach PowerShell only inside single-quoted literals (psq below doubles the
# quote character), so escaping is safe by construction. The checks here are belt and
# braces, and they also guard the two places a value is written unquoted: the ssh
# destination "user@ip" and the batch file that cmd.exe parses later.
# The regex is always one of the literals below, never user data; the value is piped in.
# Note: a case bracket expression cannot take the allowed set from a variable, because a
# quoted range such as "A-Z" matches only the literal characters A, - and Z.
strict() {
  local name="$1" value="$2" pattern="$3"
  if [ -n "$value" ] && ! printf '%s' "$value" | LC_ALL=C grep -qE "$pattern"; then
    say "ERROR: $name does not match $pattern"
    exit 1
  fi
}
strict WIN11_USER "$DESIRED_USER" '^[A-Za-z0-9._@-]+$'
strict WIN11_INIT_USER "$INIT_USER" '^[A-Za-z0-9._@-]+$'
# A KMS endpoint may carry a port, and a GVLK carries dashes.
strict WIN11_KMS "$KMS_HOST" '^[A-Za-z0-9._@:-]+$'
strict WIN11_KMS_KEY "$KMS_KEY" '^[A-Za-z0-9-]+$'

oneline() {
  local name="$1" value="$2"
  if [ "$value" != "${value//[$'\r\n']/}" ]; then
    say "ERROR: $name must be a single line"
    exit 1
  fi
}
oneline WIN11_PASSWORD "$DESIRED_PASSWORD"
oneline WIN11_INIT_PASSWORD "$INIT_PASSWORD"

# Escape a value for a PowerShell single-quoted string literal.
psq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/''/g")"; }

CHANGED=0
APPLIED=""

# Copy a file from /usr/local/share/win11 into the guest as C:\\ProgramData\\w11\\<name>.
# Base64-inlined into a PowerShell one-liner: same SSH channel as everything else,
# no SMB/SCP assumptions, immune to the escaping stack.
push_asset() {
  local name="$1" b64 script out
  b64=$(base64 < "/usr/local/share/win11/$name" | tr -d '\n')
  script="[IO.File]::WriteAllBytes('C:\\ProgramData\\w11\\$name',[Convert]::FromBase64String('$b64')); if (Test-Path 'C:\\ProgramData\\w11\\$name') { Write-Output PUSH_OK }"
  out=$(ps_run "$CUR_USER" "$CUR_PASS" "$IP" "$script")
  printf '%s' "$out" | grep -q 'PUSH_OK' || { say "ERROR: could not stage $name"; exit 1; }
}

# ---------------------------------------------------------------- account name
if [ -n "$DESIRED_USER" ] && [ "$DESIRED_USER" != "$CUR_USER" ]; then
  say "renaming account $CUR_USER -> $DESIRED_USER"
  script='Rename-LocalUser -Name '$(psq "$CUR_USER")' -NewName '$(psq "$DESIRED_USER")'; if ($?) { Write-Output RENAME_OK } else { Write-Output RENAME_FAIL; exit 1 }'
  out=$(ps_run "$CUR_USER" "$CUR_PASS" "$IP" "$script")
  if printf '%s' "$out" | grep -q 'RENAME_OK'; then
    CUR_USER="$DESIRED_USER"; CHANGED=1; APPLIED="$APPLIED user"
  else
    say "ERROR: rename failed: $(printf '%s' "$out" | tr '\n' ' ')"
    exit 1
  fi
fi

# ---------------------------------------------------------------- password
if [ -n "$DESIRED_PASSWORD" ] && [ "$DESIRED_PASSWORD" != "$CUR_PASS" ]; then
  say "setting the account password"
  script='$ErrorActionPreference="Stop"; Set-LocalUser -Name '$(psq "$CUR_USER")' -Password (ConvertTo-SecureString '$(psq "$DESIRED_PASSWORD")' -AsPlainText -Force); if ($?) { Write-Output PWD_OK }'
  out=$(ps_run "$CUR_USER" "$CUR_PASS" "$IP" "$script")
  if printf '%s' "$out" | grep -q 'PWD_OK'; then
    CUR_PASS="$DESIRED_PASSWORD"; CHANGED=1; APPLIED="$APPLIED password"
  else
    say "ERROR: password change failed: $(printf '%s' "$out" | tr '\n' ' ')"
    exit 1
  fi
fi

# ---------------------------------------------------------------- auto-logon
# The console must keep logging in unattended with the new credential, so the winlogon
# values are rewritten and then read back. Do not trust $? here: a preceding
# Remove-ItemProperty with -ErrorAction SilentlyContinue leaves $? false even on success.
if [ "$CHANGED" -eq 1 ]; then
  script='$wl="HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"; Remove-ItemProperty -Path $wl -Name ForceAutoLogon -ErrorAction SilentlyContinue; Remove-ItemProperty -Path $wl -Name AutoLogonCount -ErrorAction SilentlyContinue; Set-ItemProperty -Path $wl -Name DefaultUserName -Value '$(psq "$CUR_USER")'; Set-ItemProperty -Path $wl -Name DefaultPassword -Value '$(psq "$CUR_PASS")'; Set-ItemProperty -Path $wl -Name AutoAdminLogon -Value "1"; $k=Get-Item $wl; Write-Output ("AUTOLOGON user=" + $k.GetValue("DefaultUserName") + " autologon=" + $k.GetValue("AutoAdminLogon"))'
  out=$(ps_run "$CUR_USER" "$CUR_PASS" "$IP" "$script")
  if printf '%s' "$out" | grep -q "AUTOLOGON user=$CUR_USER autologon=1"; then
    say "unattended auto-logon synced to $CUR_USER"
  else
    say "WARNING: auto-logon not confirmed: $(printf '%s' "$out" | tr '\n' ' ')"
  fi
fi

# ---------------------------------------------------------------- activation
# LicenseStatus 1 == licensed. CIM queries are authoritative and, unlike slmgr/cscript,
# their output survives a non-console SSH pipe (cscript writes nothing there).
license_state() {
  local out
  out=$(ps_run "$CUR_USER" "$CUR_PASS" "$IP" '$l=Get-CimInstance SoftwareLicensingProduct -ErrorAction SilentlyContinue | Where-Object { $_.PartialProductKey } | Select-Object -First 1; if ($l) { Write-Output ("LICENSED=" + $l.LicenseStatus + " HOST=" + (Get-CimInstance SoftwareLicensingService).KeyManagementServiceMachine) } else { Write-Output "LICENSED=none" }')
  printf '%s' "$out" | grep -o 'LICENSED=[^ ]* HOST=.*' | head -1
}

if [ -n "$KMS_HOST" ]; then
  before=$(license_state)
  # WMI stores host and port separately, so compare against the host part only.
  if [ "$before" = "LICENSED=1 HOST=${KMS_HOST%%:*}" ]; then
    APPLIED="$APPLIED kms"
    say "already activated against $KMS_HOST"
  else
    say "activating against KMS $KMS_HOST"
    KEYLINE=""
    if [ -n "$KMS_KEY" ]; then
      KEYLINE='cscript //b //nologo $sl /ipk '$(psq "$KMS_KEY")' 2>&1 | Out-Null;'
    fi
    script='$sl="C:\Windows\System32\slmgr.vbs"; '$KEYLINE' cscript //b //nologo $sl /skms '$(psq "$KMS_HOST")' 2>&1 | Out-Null; cscript //b //nologo $sl /ato 2>&1 | Out-Null; Write-Output ACTIVATION_DONE'
    ps_run "$CUR_USER" "$CUR_PASS" "$IP" "$script" >/dev/null
    after=$(license_state)
    if printf '%s' "$after" | grep -q '^LICENSED=1'; then
      APPLIED="$APPLIED kms"
      say "license status: activated"
    else
      say "WARNING: activation not confirmed: before=$before after=$after"
    fi
  fi

  {
    printf '@echo off\r\n'
    printf 'rem Silent KMS activation; host and key were injected at deploy time.\r\n'
    printf 'rem Re-run this script if the license ever lapses (KMS renews every 7 days online).\r\n'
    printf 'set "SL=C:\\Windows\\System32\\slmgr.vbs"\r\n'
    if [ -n "$KMS_KEY" ]; then printf 'cscript //b //nologo "%%SL%%" /ipk %s\r\n' "$KMS_KEY"; fi
    printf 'cscript //b //nologo "%%SL%%" /skms %s\r\n' "$KMS_HOST"
    printf 'cscript //b //nologo "%%SL%%" /ato\r\n'
    printf 'cscript //b //nologo "%%SL%%" /dli\r\n'
  } > /tmp/activate.bat
  b64=$(base64 < /tmp/activate.bat | tr -d '\n')
  script="[IO.File]::WriteAllBytes('C:\\activate.bat',[Convert]::FromBase64String('$b64')); if (Test-Path 'C:\\activate.bat') { Write-Output BAT_OK }"
  out=$(ps_run "$CUR_USER" "$CUR_PASS" "$IP" "$script")
  printf '%s' "$out" | grep -q 'BAT_OK' && say "refreshed C:\\activate.bat"
fi

# (The reboot moved to the very end of the script: rebooting mid-way used to interrupt
#  the desktop/mspc pushes below.)

# ---------------------------------------------------------------- desktop look
# Black background, no desktop icons, taskbar auto-hidden. Two of the three are plain
# HKCU registry values and stick forever; the taskbar switch exists only as runtime
# state on this build (the StuckRects3 registry route is measurably dead), so it has
# to be replayed after every boot by a logon task. Both scripts therefore run from
# one Interactive/Highest task in the console session: SYSTEM and sshd children live
# in session 0, where FindWindow('Shell_TrayWnd') returns 0 and the call no-ops.
if [ "$DESKTOP" != "off" ]; then
  say "applying desktop look (black, no icons, taskbar auto-hide)"
  ps_run "$CUR_USER" "$CUR_PASS" "$IP" 'New-Item -ItemType Directory -Path C:\ProgramData\w11 -Force | Out-Null; Write-Output DIR_OK' >/dev/null
  push_asset w11_desktop.ps1
  push_asset tb_ensure_hidden.ps1

  # cmd wrapper + bat so the task leaves a log behind; the bat is echoed back because a
  # mangled bat silently loses arguments in this stack (WeChat install incident).
  desk_script='$d="C:\ProgramData\w11"; $b=$d+"\deskhide.bat"; $l=$d+"\deskhide.log"; $s=@(); $s+=("@echo off"); $s+=("powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File " + $d + "\w11_desktop.ps1 > " + $l + " 2>&1"); $s+=("powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File " + $d + "\tb_ensure_hidden.ps1 >> " + $l + " 2>&1"); $s+=("echo DONE_EXIT=%ERRORLEVEL% >> " + $l); Set-Content -Path $b -Value $s -Encoding ASCII; Get-Content $b | ForEach-Object { Write-Output ("BATHASH[" + $_ + "]") }; Write-Output BAT_OK'
  out=$(ps_run "$CUR_USER" "$CUR_PASS" "$IP" "$desk_script")
  printf '%s' "$out" | grep -q 'BAT_OK' || { say "ERROR: deskhide.bat not written"; exit 1; }
  printf '%s' "$out" | tr -d '\r' | grep -o 'BATHASH\[.*\]' | while read -r l; do say "  $l"; done

  desk_script='$null = Register-ScheduledTask -TaskName w11DeskHide -Action (New-ScheduledTaskAction -Execute cmd.exe -Argument "/c C:\ProgramData\w11\deskhide.bat") -Principal (New-ScheduledTaskPrincipal -UserId '$(psq "$CUR_USER")' -LogonType Interactive -RunLevel Highest) -Trigger (New-ScheduledTaskTrigger -AtLogOn -User '$(psq "$CUR_USER")') -Settings (New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 15)) -Force -ErrorAction Stop; $x = Get-ScheduledTask -TaskName w11DeskHide; Write-Output ("TASK=" + $x.TaskName + " " + $x.Principal.UserId + "/" + $x.Principal.LogonType + "/" + $x.Principal.RunLevel); Start-ScheduledTask -TaskName w11DeskHide; Write-Output TASK_STARTED'
  out=$(ps_run "$CUR_USER" "$CUR_PASS" "$IP" "$desk_script")
  if printf '%s' "$out" | grep -q 'TASK_STARTED'; then
    say "$(printf '%s' "$out" | tr -d '\r' | grep -o 'TASK=.*' | head -1)"
    APPLIED="$APPLIED desktop"
  else
    say "WARNING: logon task not registered: $(printf '%s' "$out" | tr '\n' ' ')"
  fi
fi

# ---------------------------------------------------------------- midscene-pc API server
# A payload tarball built FROM A LIVE VM (win32 node_modules + node.exe; never npm-install
# from a Linux image) ships inside the image. The injector pushes it over scp on the same
# SSH channel, then a one-shot w11Mspc task (Interactive/Highest: the console session is
# required for window APIs and screenshots) unpacks it, writes C:\mspc\.env from a
# JSON sidecar, and registers mspcServer (AtLogOn Interactive) as the persistent API host.
# Values NEVER travel as task arguments: they would have to survive bash -> task XML ->
# cmd -> PowerShell and corrupt silently (the WeChat bat incident).
if [ "$MSPC" != "off" ] && [ -f /usr/local/share/win11/mspc-payload.tar.gz ]; then
  strict WIN11_MSPC_TOKEN "$MSPC_TOKEN" '^[A-Za-z0-9._@-]+$'
  strict WIN11_MSPC_GATEWAY "$MSPC_GATEWAY" '^[A-Za-z0-9./:_+-]+$'
  strict WIN11_MSPC_MODEL_KEY "$MSPC_MODEL_KEY" '^[A-Za-z0-9._-]+$'
  strict WIN11_MSPC_MODEL "$MSPC_MODEL" '^[A-Za-z0-9._-]+$'
  strict WIN11_MSPC_FAMILY "$MSPC_FAMILY" '^[A-Za-z0-9._-]+$'
  if [ -n "$MSPC_TOKEN" ]; then say "deploying midscene-pc API (:3333, token-protected)"; else say "deploying midscene-pc API (:3333, no token -> guest loopback only)"; fi
  MSPC_VERSION=$(sha256sum /usr/local/share/win11/mspc-payload.tar.gz | cut -c1-12)
  push_asset w11_mspc.ps1
  # Sidecar carries every injected value; rewritten on every start so a token or gateway
  # change in .env takes effect without re-pushing the payload.
  sed -e "s/__VERSION__/$MSPC_VERSION/" -e "s|__TOKEN__|$MSPC_TOKEN|" -e "s|__GATEWAY__|$MSPC_GATEWAY|" \
      -e "s|__KEY__|$MSPC_MODEL_KEY|" -e "s|__MODEL__|$MSPC_MODEL|" -e "s|__FAMILY__|$MSPC_FAMILY|" \
    /usr/local/share/win11/mspc-args.json.template > /tmp/mspc-args.json
  grep -q '__' /tmp/mspc-args.json && { say 'ERROR: mspc template substitution failed'; exit 1; }
  b64=$(base64 < /tmp/mspc-args.json | tr -d '\n'); rm -f /tmp/mspc-args.json
  script="[IO.File]::WriteAllBytes('C:\\ProgramData\\w11\\mspc-args.json',[Convert]::FromBase64String('$b64')); Write-Output ARGS_OK"
  out=$(ps_run "$CUR_USER" "$CUR_PASS" "$IP" "$script")
  printf '%s' "$out" | grep -q ARGS_OK || { say 'ERROR: mspc args sidecar failed'; exit 1; }
  # Firewall hygiene, run TWICE (here and after the API is up): Windows records a
  # per-program BLOCK rule the moment node first binds a port in a new guest, and the
  # seed disk already carries two such rules from win11-en ("Node.js JavaScript
  # Runtime"). Block beats Allow, so the API is unreachable from outside until they are
  # gone (found 2026-09-05). The post-UP pass catches rules created by that first bind.
  mspc_fw_hygiene() {
  fw="Get-NetFirewallRule -ErrorAction SilentlyContinue | Where-Object { \$_.DisplayName -eq 'Node.js JavaScript Runtime' -and \$_.Action -eq 'Block' } | Remove-NetFirewallRule -ErrorAction SilentlyContinue; if (-not (Get-NetFirewallPortFilter -ErrorAction SilentlyContinue | Where-Object { \$_.LocalPort -eq '3333' } | Select-Object -First 1)) { New-NetFirewallRule -DisplayName 'midscene-pc API' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 3333 -Profile Any | Out-Null }; \$b = @(Get-NetFirewallRule -ErrorAction SilentlyContinue | Where-Object { \$_.Action -eq 'Block' -and \$_.Direction -eq 'Inbound' -and \$_.Enabled -eq 'True' } | Measure-Object).Count; Write-Output ('FWOK blocks=' + \$b)"
    out=$(ps_run "$CUR_USER" "$CUR_PASS" "$IP" "$fw")
    # Rule COUNTS are noisy (Windows hydrates them lazily around the first bind; a fresh
    # guest counted 1 here even while the API answered from outside). The only verdict
    # that matters is reachability, checked after the server is up below.
    printf '%s' "$out" | grep -q 'FWOK' || say 'WARNING: firewall hygiene did not report'
  }
  mspc_fw_hygiene
  # Push the tarball when the marker differs, or when it matches but the install is
  # broken (marker written, node.exe gone) -- self-heal instead of a mystery DOWN.
  have=$(ps_run "$CUR_USER" "$CUR_PASS" "$IP" '$m = ""; if (Test-Path "C:\mspc\.mspc-version") { $m = (Get-Content "C:\mspc\.mspc-version" -First 1).Trim() }; $n = Test-Path "C:\mspc\bin\node.exe"; Write-Output ("MARKER=" + $m + " NODE=" + $n)')
  if printf '%s' "$have" | grep -q "MARKER=$MSPC_VERSION NODE=True"; then
    say "payload $MSPC_VERSION already on disk (not re-pushed)"
  else
    say "pushing mspc payload $MSPC_VERSION (~80 MB, one time) ..."
    printf '%s' "$CUR_PASS" > /tmp/.mspc_pw; chmod 600 /tmp/.mspc_pw
    sshpass -f /tmp/.mspc_pw scp -P 22 -q $SSH_OPTS -o StrictHostKeyChecking=no \
      /usr/local/share/win11/mspc-payload.tar.gz "$CUR_USER@$IP:C:/ProgramData/w11/mspc-payload.tar.gz"
    scp_rc=$?; rm -f /tmp/.mspc_pw
    [ $scp_rc -eq 0 ] || { say "ERROR: mspc payload push failed (rc=$scp_rc)"; exit 1; }
  fi
  reg='if (Test-Path C:\ProgramData\w11\mspc-deploy.log) { Remove-Item C:\ProgramData\w11\mspc-deploy.log -Force }; $null = Register-ScheduledTask -TaskName w11Mspc -Action (New-ScheduledTaskAction -Execute cmd.exe -Argument "/c powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\ProgramData\w11\w11_mspc.ps1 > C:\ProgramData\w11\mspc-once.log 2>&1") -Principal (New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest) -Settings (New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 10)) -Force; Start-ScheduledTask -TaskName w11Mspc; Write-Output ONESHOT_STARTED'
  ps_run "$CUR_USER" "$CUR_PASS" "$IP" "$reg" | grep -q ONESHOT_STARTED || { say 'ERROR: mspc deploy task not started'; exit 1; }
  i=0
  while [ $i -lt 36 ]; do
    i=$((i+1)); sleep 5
    v=$(ps_run "$CUR_USER" "$CUR_PASS" "$IP" 'Get-Content C:\ProgramData\w11\mspc-deploy.log -ErrorAction SilentlyContinue | Select-Object -Last 3')
    if printf '%s' "$v" | grep -q 'MSPC_API=.* UP'; then
      # The very first bind may have made Windows file a fresh block rule for node.exe;
      # sweep again now that it exists, then prove the API answers from OUTSIDE the guest
      # (host-side port-forward is what operators use; a guest-local check would be blind
      # to exactly the failure this hygiene prevents).
      mspc_fw_hygiene
      # Prove the API answers from OUTSIDE the guest: reaching guest:3333 from this
      # container is the same vantage an operator's port-forward uses, so it catches
      # exactly the seed-carried block-rule failure.
      if tcp_open "$IP" 3333; then say 'midscene-pc API up and reachable on :3333'
      else say 'WARNING: mspc API listening but unreachable through the NAT (firewall?)'; fi
      APPLIED="$APPLIED mspc"; break
    fi
    if printf '%s' "$v" | grep -q 'MSPC_API=DOWN'; then say "WARNING: mspc deployed but API down (see C:\ProgramData\w11\mspc-server.log)"; break; fi
    if printf '%s' "$v" | grep -q 'ERROR:'; then say "ERROR: mspc deploy failed: $v"; exit 1; fi
  done
    ps_run "$CUR_USER" "$CUR_PASS" "$IP" '$null = Unregister-ScheduledTask -TaskName w11Mspc -Confirm:$false' >/dev/null 2>&1
fi

# ---------------------------------------------------------------- reboot once (last step)
if [ "$CHANGED" -eq 1 ]; then
  say "rebooting the guest so auto-logon uses the new credential"
  ps_run "$CUR_USER" "$CUR_PASS" "$IP" 'shutdown /r /t 5 /f' >/dev/null 2>&1
fi
say "done (applied:$APPLIED)"
exit 0
