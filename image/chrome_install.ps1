# chrome_install.ps1 -- one-shot, run by the injector as a SYSTEM task.
# Chrome is the only third-party software this image carries (user decision
# 2026-09-06): offline Enterprise MSI (never the stub bootstrapper -- no network at
# install time) plus HKLM policies that make the first launch land straight on the
# new-tab page: no sign-in prompt, no translation bubble.
#   BrowserSignin=0 / SigninAllowed=0  -> no "sign in to Chrome" dialog (enterprise
#     policy beats the --no-first-run flag: it survives any launch path)
#   TranslateEnabled=0                 -> never offer to translate a page
#   FirstRunTab=none + PromotionalTabsEnabled=0 + WelcomePageOnOSUpgradeEnabled=0
#                                      -> no welcome/promo tab, straight to NTP
# Idempotent via C:\chrome\.chrome-version (payload hash); the injector skips the
# whole task when the marker matches, and this script re-checks before installing.
$ErrorActionPreference = 'Continue'
$log = 'C:\ProgramData\w11\chrome-install.log'
function Log($m) { Add-Content -Path $log -Value ((Get-Date -Format o) + ' ' + $m) }
$want = '1c555a95c691'
$exe = 'C:\Program Files\Google\Chrome\Application\chrome.exe'
$marker = 'C:\chrome\.chrome-version'
try {
  if ((Test-Path $marker) -and (Test-Path $exe) -and ((Get-Content $marker -First 1).Trim() -eq $want)) {
    Log 'SKIP_ALREADY_INSTALLED'
    Write-Output 'CHROME_SKIPPED'
    exit 0
  }
  Log 'START'
  $src = 'C:\ProgramData\w11\ChromeEnt64.msi'
  if (-not (Test-Path $src)) { throw 'payload missing' }
  $p = Start-Process msiexec.exe -ArgumentList '/i', $src, '/qn', '/norestart', '/l*v', 'C:\Windows\Temp\chrome_msi.log' -Wait -PassThru
  Log ('MSI_RC=' + $p.ExitCode)
  if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) { throw ('msiexec rc ' + $p.ExitCode) }
  if (-not (Test-Path $exe)) { throw 'chrome.exe missing after install' }
  $pol = 'HKLM:\SOFTWARE\Policies\Google\Chrome'
  if (-not (Test-Path $pol)) { New-Item -Path $pol -Force | Out-Null }
  Set-ItemProperty -Path $pol -Name BrowserSignin -Value 0 -Type DWord
  Set-ItemProperty -Path $pol -Name SigninAllowed -Value 0 -Type DWord
  Set-ItemProperty -Path $pol -Name TranslateEnabled -Value 0 -Type DWord
  Set-ItemProperty -Path $pol -Name FirstRunTab -Value 'none' -Type String
  Set-ItemProperty -Path $pol -Name PromotionalTabsEnabled -Value 0 -Type DWord
  Set-ItemProperty -Path $pol -Name WelcomePageOnOSUpgradeEnabled -Value 0 -Type DWord
  $v = Get-ItemProperty $pol
  Log ('POL BrowserSignin=' + $v.BrowserSignin + ' SigninAllowed=' + $v.SigninAllowed + ' Translate=' + $v.TranslateEnabled + ' FirstRunTab=' + $v.FirstRunTab)
  # Google Update service + scheduled tasks: keep the package static (the image is
  # the product), but leave the binaries alone -- removing them would break the MSI
  # repair path.
  $gu = 'HKLM:\SOFTWARE\Policies\Google\Update'
  if (-not (Test-Path $gu)) { New-Item -Path $gu -Force | Out-Null }
  Set-ItemProperty -Path $gu -Name UpdateDefault -Value 0 -Type DWord
  Set-ItemProperty -Path $gu -Name InstallDefault -Value 'C:\Program Files\Google\Chrome' -Type String
  New-Item -ItemType Directory -Path 'C:\chrome' -Force | Out-Null
  Set-Content -Path $marker -Value $want -Encoding ASCII
  Log ('VER=' + (Get-Item $exe).VersionInfo.ProductVersion)
  Log 'DONE'
  Write-Output 'CHROME_INSTALLED'
} catch {
  Log ('FAILED=' + $_.Exception.Message)
  Write-Output 'CHROME_FAILED'
  exit 1
}
