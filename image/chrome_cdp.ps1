# chrome_cdp.ps1 -- keep a CDP-enabled Chrome reachable on 0.0.0.0:<port> inside the
# console session. Registered by the injector as w11CdpChrome (AtLogOn / Interactive /
# Highest) and triggered once at deploy time; survives guest reboots (mspcServer pattern)
# and supervises itself afterwards (the task never exits; a second trigger is ignored by
# the single-instance policy -- this task IS the watchdog).
#
# Why a portproxy instead of a bind flag: Chrome >=136 refuses to bind DevTools to
# anything beyond loopback (security change; --remote-debugging-address=0.0.0.0 is
# accepted and silently ignored -- measured on 152.0.7977.83). So chrome listens on
# 127.0.0.1:<port+1> and a netsh portproxy owns 0.0.0.0:<port> for the container NAT.
# portproxy config requires elevation -- the Highest token here holds it, the
# UAC-filtered SSH token does not.
#
# Why the remaining flags:
#   --remote-allow-origins=*   DevTools WS handshakes through the NAT look cross-origin
#                              (Chrome >=111 rejects them otherwise).
#   --user-data-dir=<profile>  debug port binds per-process; CDP gets its own clean
#                              profile instead of the interactive default one (Chrome
#                              >=136 refuses a debug port on the default profile too).
# Port source of truth: C:\ProgramData\w11\cdp.port (written by the injector),
# fallback 9222 (the shipped default; the HOST-side port is what compose parameterizes,
# same shape as mspc: guest fixed, host mapped). Public port P, chrome internal P+1.
$ErrorActionPreference = 'Continue'
$log = 'C:\ProgramData\w11\cdp.log'
function Log($m) { Add-Content -Path $log -Value ((Get-Date -Format o) + ' ' + $m) }
$port = 9222
$pf = 'C:\ProgramData\w11\cdp.port'
if (Test-Path $pf) { $t = 0; if ([int]::TryParse(((Get-Content $pf -First 1).Trim()), [ref]$t)) { if ($t -ge 1024 -and $t -le 65534) { $port = $t } } }
$cport = $port + 1
$exe = 'C:\Program Files\Google\Chrome\Application\chrome.exe'
if (-not (Test-Path $exe)) { Log 'CDP_SKIPPED_NO_CHROME'; Write-Output 'CDP_SKIPPED'; exit 0 }

function CdpUp {
  try {
    $r = Invoke-WebRequest -UseBasicParsing -Uri ('http://127.0.0.1:' + $cport + '/json/version') -TimeoutSec 5
    return ($r.StatusCode -eq 200)
  } catch { return $false }
}
function EnsureProxy {
  # idempotent: always rewrite the v4:0.0.0.0:<port> rule to the current target
  netsh interface portproxy delete v4tov4 listenaddress=0.0.0.0 "listenport=$port" | Out-Null
  netsh interface portproxy add v4tov4 listenaddress=0.0.0.0 "listenport=$port" "connectaddress=127.0.0.1" "connectport=$cport" | Out-Null
}
function ProxyUp {
  try {
    $r = Invoke-WebRequest -UseBasicParsing -Uri ('http://127.0.0.1:' + $port + '/json/version') -TimeoutSec 5
    return ($r.StatusCode -eq 200)
  } catch { return $false }
}

# --- firewall: allow the PUBLIC port; and mirror the mspc lesson -- Windows can
# --- record a per-program BLOCK rule for chrome at first bind, Block beats Allow.
try {
  Get-NetFirewallRule -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -eq 'Google Chrome' -and $_.Action -eq 'Block' } |
    Remove-NetFirewallRule -ErrorAction SilentlyContinue
  $existing = Get-NetFirewallPortFilter -ErrorAction SilentlyContinue | Where-Object { $_.LocalPort -eq "$port" }
  if (-not $existing) {
    New-NetFirewallRule -DisplayName 'w11 Chrome CDP' -Direction Inbound -Action Allow -Protocol TCP -LocalPort $port -Profile Any | Out-Null
  }
  Log ('FIREWALL_OK port=' + $port)
} catch {
  Log ('FIREWALL_FAILED=' + $_.Exception.Message)
}
# portproxy traffic is judged against the connecting service (svchost/iphlpsvc); the
# loopback probe below cannot see that block -- the container-side verdict in the
# injector is the authority.

try { EnsureProxy; Log ('PROXY_OK ' + $port + '->' + $cport) } catch { Log ('PROXY_FAILED=' + $_.Exception.Message) }

$cargs = @(
  ('--remote-debugging-port=' + $cport),
  '--remote-allow-origins=*',
  '--user-data-dir=C:\ProgramData\w11\cdp-profile',
  '--no-first-run',
  '--no-default-browser-check',
  '--hide-crash-restore-bubble',
  '--disable-session-crashed-bubble',
  '--disable-backgrounding-occluded-windows',
  '--disable-renderer-backgrounding'
)

if (-not (CdpUp)) {
  Log ('LAUNCH cport=' + $cport)
  Start-Process $exe -ArgumentList $cargs
  for ($i = 1; $i -le 20; $i++) {
    Start-Sleep -Seconds 3
    if (CdpUp) { break }
  }
}
if (-not (CdpUp)) { Log 'CDP_DOWN'; Write-Output 'CDP_DOWN'; exit 1 }
if (ProxyUp) { Log ('UP port=' + $port + ' (public via portproxy)'); Write-Output 'CDP_UP' }
else { Log 'WARN chrome up but public probe failed (firewall? iphlpsvc?)'; Write-Output 'CDP_UP' }

# Supervisor loop: relaunch chrome if it dies; re-assert the proxy when the public
# endpoint degrades (stale rule, iphlpsvc restart).
while ($true) {
  Start-Sleep -Seconds 15
  if (-not (CdpUp)) {
    Log 'supervisor: chrome gone, relaunching'
    Start-Process $exe -ArgumentList $cargs
    for ($i = 1; $i -le 20; $i++) {
      Start-Sleep -Seconds 3
      if (CdpUp) { Log 'supervisor: back up'; break }
    }
  }
  if (-not (ProxyUp)) {
    Log 'supervisor: public endpoint down, re-asserting proxy'
    try { EnsureProxy } catch { Log ('PROXY_FAILED=' + $_.Exception.Message) }
  }
}
