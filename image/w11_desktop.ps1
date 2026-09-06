# w11_desktop.ps1 -- one desktop-look pass, run inside the console session.
# Invoked by the w11DeskHide logon task (cmd wrapper), before tb_ensure_shown.ps1.
# Look (measured on w11-tbtest, 25H2 / 26100.7840, 2026-09-06): solid black wallpaper,
# no desktop icons, taskbar icons LEFT-aligned, no search box, no Microsoft Store pin.
# The always-visible taskbar itself is enforced by tb_ensure_shown.ps1, the next step
# of the same logon task.
# Idempotent: registry writes are cheap and repeated; explorer restarts only when THIS
# run flipped something the shell reads at startup (NoDesktop / TaskbarAl) -- on a warm
# volume both are already in place, so no restart fires on ordinary container starts.
# TaskbarAl semantics are Microsoft-documented: 0 = left aligned, 1 = centered.
# Store unpin: the TaskbarDa policy is accepted silently on 26100 but does NOT remove
# the pin (measured); the AppsFolder verb DoIt() does, and it works from any session.
# Once unpinned the verb list loses Unpin, so later runs print STORE_CLEAN and no-op.
# Why here and not in provision.ps1: this image derives from a sealed disk; the
# provision chain ran once at install time. The injector re-applies the look at every
# container start, so the look survives even if the volume is older than the image.
$ErrorActionPreference = 'Continue'

# --- solid black wallpaper (base disk already carries this; re-assert cheaply) ---
$dp = 'HKCU:\Control Panel\Desktop'
Set-ItemProperty -Path $dp -Name Wallpaper -Value ''
Set-ItemProperty -Path $dp -Name WallpaperStyle -Value '10'
Set-ItemProperty -Path $dp -Name TileWallpaper -Value '0'
Set-ItemProperty -Path 'HKCU:\Control Panel\Colors' -Name Background -Value '0 0 0'
Remove-Item -Path 'HKCU:\Control Panel\Desktop\Slideshow' -Recurse -Force -ErrorAction SilentlyContinue

# --- taskbar shape: icons left-aligned, no search box (shell reads both at startup) ---
$kv = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
$ki = Get-ItemProperty $kv -ErrorAction SilentlyContinue
$prevAl = 'ABSENT'
if ($ki -and ($ki.PSObject.Properties.Name -contains 'TaskbarAl')) { $prevAl = $ki.TaskbarAl }
Set-ItemProperty -Path $kv -Name TaskbarAl -Value 0 -Type DWord
$sch = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search'
if (-not (Test-Path $sch)) { New-Item -Path $sch -Force | Out-Null }
Set-ItemProperty -Path $sch -Name SearchboxTaskbarMode -Value 0 -Type DWord

# --- hide every desktop icon (recycle bin, public .lnk files, dockur junction) ---
$pol = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer'
if (-not (Test-Path $pol)) { New-Item -Path $pol -Force | Out-Null }
$prev = (Get-ItemProperty $pol -ErrorAction SilentlyContinue).NoDesktop
Set-ItemProperty -Path $pol -Name NoDesktop -Value 1 -Type DWord

# --- dockur's SetupComplete creates one junction; removing it is permanent ---
$sh = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Shared'
if (Test-Path $sh) {
  cmd.exe /c ('rmdir "' + $sh + '"') 2>&1 | Out-Null
  Write-Output ('SHARED_GONE=' + (-not (Test-Path $sh)))
}

# --- unpin the Microsoft Store from the taskbar (route proven 2026-09-06) ---
try {
  $shellApp = New-Object -ComObject Shell.Application
  $apps = $shellApp.Namespace('shell:AppsFolder')
  $store = $apps.ParseName('Microsoft.WindowsStore_8wekyb3d8bbwe!App')
  if ($store) {
    $verb = $store.Verbs() | Where-Object { ($_.Name -replace '&', '') -like '*Unpin*' }
    if ($verb) {
      $verb.DoIt()
      Start-Sleep -Seconds 3
      Write-Output 'STORE_UNPINNED'
    } else {
      Write-Output 'STORE_CLEAN'
    }
  } else { Write-Output 'STORE_APPX=missing' }
} catch {
  Write-Output ('STORE_UNPIN_FAILED=' + $_.Exception.Message)
}

# --- silencing that keeps the black desktop from being dressed back up ---
$cdm = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
foreach ($k in @('RotatingLockScreenEnabled','RotatingLockScreenOverlayEnabled','SilentlyInstalledAppsEnabled','PreInstalledAppsEnabled','ShowFeatureSuggestionsOnTaskbar','SubscribedContent-338389Enabled')) {
  Set-ItemProperty -Path $cdm -Name $k -Value 0 -Type DWord -ErrorAction SilentlyContinue
}
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization' -Name NoLockScreen -Value 1 -Type DWord -ErrorAction SilentlyContinue

# --- repaint this session ---
try {
  if (-not ('Win32.Desktop' -as [type])) {
    Add-Type -Namespace Win32 -Name Desktop -MemberDefinition @"
[DllImport("user32.dll", SetLastError = true)]
public static extern int SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni);
"@
  }
  [Win32.Desktop]::SystemParametersInfo(20, 0, "", 3) | Out-Null
} catch { }

# NoDesktop and TaskbarAl are read by the shell at startup, so restart explorer once
# when this run flipped either (fresh volume first boot). This runs inside the
# Interactive logon task -- the console session -- which is the only place a shell
# restart lands on the visible desktop (AGENTS.md: never from SYSTEM or sshd). The
# restart happens here so tb_ensure_shown.ps1's own wait-for-tray loop sees a settled
# shell right after.
if (($prev -ne 1) -or ($prevAl -eq 'ABSENT') -or ($prevAl -ne 0)) {
  taskkill /f /im explorer.exe 2>&1 | Out-Null
  Start-Sleep -Seconds 4
  Start-Process 'C:\Windows\explorer.exe'
  Start-Sleep -Seconds 15
  Write-Output 'EXPLORER_RESTARTED'
}

Write-Output ('NODESKTOP=' + (Get-ItemProperty $pol).NoDesktop)
$ki2 = Get-ItemProperty $kv
$si2 = Get-ItemProperty $sch
Write-Output ('TASKBARAL=' + $ki2.TaskbarAl + ' SEARCH=' + $si2.SearchboxTaskbarMode)
Write-Output 'DESKTOP_DONE'
