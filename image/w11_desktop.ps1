# w11_desktop.ps1 -- one desktop-look pass, run inside the console session.
# Invoked by the w11DeskHide logon task (cmd wrapper), before tb_ensure_hidden.ps1.
# Idempotent: registry writes only when needed, the junction removal is one-shot,
# explorer restarts only when NoDesktop was actually flipped in this run.
#
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

# NoDesktop is read by the shell at startup; restart explorer once when we just
# flipped it so the icons vanish in this session too. Console session only -- this
# script only ever runs from the Interactive logon task.
if ($prev -ne 1) {
  taskkill /f /im explorer.exe 2>&1 | Out-Null
  Start-Sleep -Seconds 4
  Start-Process 'C:\Windows\explorer.exe'
  Start-Sleep -Seconds 15
  Write-Output 'EXPLORER_RESTARTED'
}

Write-Output ('NODESKTOP=' + (Get-ItemProperty $pol).NoDesktop)
Write-Output 'DESKTOP_DONE'
